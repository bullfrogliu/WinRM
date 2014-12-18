require 'io/console'
require 'json'
require_relative '../helpers/powershell_script'

module WinRM
  class RemoteFile

    attr_reader :local_path
    attr_reader :remote_path
    attr_reader :temp_path
    attr_reader :shell

    def initialize(service, local_path, remote_path, remote_temp_dir)
      @logger = Logging.logger[self]
      @service = service
      @local_path = local_path
      @remote_path = remote_path
      #@temp_path = File.join(remote_temp_dir, "winrm-upload-#{rand()}").gsub('\\', '/')
    end

    def upload(&block)
      @logger.debug("Uploading file: #{@local_path} -> #{@remote_path}")
      raise WinRMUploadError.new("Cannot find path: #{@local_path}") unless File.exist?(@local_path)

      @shell = @service.open_shell()
      @temp_path = run_powershell(resolve_tempfile_command).chomp

      if !@temp_path.to_s.empty?
        size = upload_to_tempfile(&block)
        run_powershell(decode_tempfile_command)
      else
        size = 0
        @logger.debug("Files are equal. Not copying #{@local_path} to #{@remote_path}")
      end

      return size
    ensure
      @service.close_shell(@shell) if @shell
    end
    
    protected

    def upload_to_tempfile(&block)
      @logger.debug("Uploading to temp file #{@temp_path}")
      base64_host_file = Base64.encode64(IO.binread(@local_path)).gsub("\n", "")
      base64_array = base64_host_file.chars.to_a
      bytes_copied = 0
      if base64_array.empty?
        run_powershell(create_empty_destfile_command)
      else
        base64_array.each_slice(8000 - @temp_path.size) do |chunk|
          run_cmd("echo #{chunk.join} >> \"#{@temp_path}\"")
          bytes_copied += chunk.count
          yield bytes_copied, base64_array.count, @local_path, @remote_path if block_given?
        end
      end
      base64_array.length
    end

    def run_powershell(script_text)
      script = WinRM::PowershellScript.new(script_text)
      run_cmd("powershell", ['-encodedCommand', script.encoded()])
    end

    def run_cmd(command, arguments = [])
      result = nil
      @service.run_command(@shell, command, arguments) do |command_id|
        result = @service.get_command_output(@shell, command_id)
      end

      if result[:exitcode] != 0 || result.stderr.length > 0
        raise WinRMUploadError,
          :from => @local_path,
          :to => @remote_path,
          :message => result.output
      end

      result.stdout
    end


    def resolve_tempfile_command()
      local_md5 = Digest::MD5.file(@local_path).hexdigest
      <<-EOH
        # get the resolved target path
        $destFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath("#{@remote_path}")

        # check if file is up to date
        if (Test-Path $destFile) {
          $cryptoProv = New-Object -TypeName System.Security.Cryptography.MD5CryptoServiceProvider

          $file = [System.IO.File]::Open($destFile,
            [System.IO.Filemode]::Open, [System.IO.FileAccess]::Read)
          $guestMd5 = ([System.BitConverter]::ToString($cryptoProv.ComputeHash($file)))
          $guestMd5 = $guestMd5.Replace("-","").ToLower()
          $file.Close()

          # file content is up to date, send back an empty file path to signal this
          if ($guestMd5 -eq '#{local_md5}') {
            return ''
          }
        }

        # file doesn't exist or out of date, return a unique temp file path to upload to
        return [System.IO.Path]::GetTempFileName()
      EOH
    end

    def decode_tempfile_command()
      <<-EOH
        $tempFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath('#{@temp_path}')
        $destFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath('#{@remote_path}')

        # ensure the file's containing directory exists
        $destDir = ([System.IO.Path]::GetDirectoryName($destFile))
        if (!(Test-Path $destDir)) {
          New-Item -ItemType directory -Force -Path $destDir | Out-Null
        }

        # get the encoded temp file contents, decode, and write to final dest file
        $base64Content = Get-Content $tempFile
        if ($base64Content -eq $null) {
          New-Item -ItemType file -Force $destFile
        } else {
          $bytes = [System.Convert]::FromBase64String($base64Content)
          [System.IO.File]::WriteAllBytes($destFile, $bytes) | Out-Null
        }
      EOH
    end

    def create_empty_destfile_command()
      <<-EOH
        $destFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath('#{@remote_path}')
        New-Item $destFile -type file
      EOH
    end

  end
end
