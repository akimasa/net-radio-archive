require 'shellwords'

module NiconicoLive
  class Downloading
    CH_NAME = 'niconama'

    class NiconamaDownloadException < StandardError; end
    class NiconamaInternalProcessedException < StandardError; end

    def download(program)
      @log_buffer = []
      @program = program
      begin
        setup
        reservation
      rescue NiconamaInternalProcessedException => e
        return
      rescue Exception => e
        unless @log_buffer.empty?
          Rails.logger.warn @log_buffer.join("\n")
        end
        Rails.logger.error e.class
        Rails.logger.error e.inspect
        Rails.logger.error e.backtrace.join("\n")
        program.state = NiconicoLiveProgram::STATE[:failed_before_got_rtmp_url]
        return
      end

      begin
        _download
      rescue NiconamaInternalProcessedException => e
        return
      rescue Exception => e
        unless @log_buffer.empty?
          Rails.logger.warn @log_buffer.join("\n")
        end
        Rails.logger.error e.class
        Rails.logger.error e.inspect
        Rails.logger.error 'quesheet:'
        pp @l.quesheet
        Rails.logger.error e.backtrace.join("\n")
        program.state = NiconicoLiveProgram::STATE[:failed_dumping_rtmp]
        return
      end
      program.state = NiconicoLiveProgram::STATE[:done]
    end

    def setup
      @n = Niconico.new(Settings.niconico.username, Settings.niconico.password)
      @n.login
      @c = @n.live_client
      @a = Niconico::Live::API.new(@n.agent)
      remove_timeshifts
      @l = @n.live(@program.id)
      @l.get
    end

    def remove_timeshifts
      ids = @a.watching_reservations.delete_if do |id|
        Niconico::Live::Util::normalize_id(id) ==
        Niconico::Live::Util::normalize_id(@program.id)
      end
      @c.remove_timeshifts(ids)
    end

    def reservation
      begin
        @l.accept_reservation
      rescue Mechanize::ResponseCodeError, NoMethodError => e
        # <NoMethodError: undefined method `inner_text' for nil:NilClass>
        # lib/niconico/live/api.rb:60:in `get'

        @log_buffer << "reservation failed. but try continue"
        @log_buffer << e.class
        @log_buffer << e.inspect
        @log_buffer << e.backtrace.join("\n")

        # force reload
        sleep 5
        @l.get(true)
      end

      # fetch lazy load objects
      begin
        @l.quesheet
      rescue Niconico::Live::TicketRetrievingFailed => e
        case e.message
        when 'usertimeshift'
          @program.cannot_recovery = true
          @program.memo = 'getplayerstatus error: usertimeshift. コミュニティ限定放送'
        when 'noauth'
          @program.cannot_recovery = true
          @program.memo = 'getplayerstatus error: noauth. 公式の有料生放送で視聴権限なし'
        when 'tsarchive'
          @program.cannot_recovery = true
          @program.memo = 'getplayerstatus error: tsarchive. チャンネルの途中から有料放送'
        else
          @program.memo = "getplayerstatus error: #{e.message}"
          raise e
        end
        @program.state = NiconicoLiveProgram::STATE[:failed]
        raise NiconamaInternalProcessedException, ''
      end
    end

    def _download
      Main::prepare_working_dir(CH_NAME)

      path = filepath(@l)
      succeed_count = 0
      infos = @l.rtmpdump_infos(path)
      infos.each do |info|
        full_file_path = info[:file_path]
        exit_status, output = rtmpdump_with_retry(info)
        unless exit_status.success?
          @log_buffer << "rtmpdump failed: #{@l.id}, #{full_file_path} but continue other file download"
          @log_buffer << output
          next
        end
        unless Main::check_file_size(full_file_path)
          @log_buffer << "downloaded file is not valid: #{@l.id}, #{full_file_path} but continue other file download"
          next
        end
        converted_path = full_file_path.gsub(/\.flv$/, '') + '.mkv'
        Main::convert_ffmpeg_to_mp4(full_file_path, converted_path, @program)
        unless Main::check_file_size(converted_path)
          @log_buffer << "coverted file is not valid: #{@l.id}, #{converted_path} but continue other file download"
          next
        end
        Main::move_to_archive_dir(CH_NAME, @l.opens_at, converted_path)
        succeed_count += 1
      end
      if succeed_count == 0
        raise NiconamaDownloadException, "download failed."
      end
    end

    def rtmpdump_with_retry(info)
      exit_status = nil
      output = nil
      5.times do
        exit_status, output = rtmpdump_with_resume(info)
        if exit_status.success?
          break
        end
        sleep 10
      end
      [exit_status, output]
    end

    def rtmpdump_with_resume(info)
      exit_status, output = Main::shell_exec(rtmpdump_command(info, false))
      10.times do
        if exit_status.exitstatus != 2 # 2 means 'Incomplete transfer, resuming may get further. '
          return [exit_status, output]
        end
        sleep 5
        exit_status, output = Main::shell_exec(rtmpdump_command(info, true))
      end
      [exit_status, output]
    end

    def rtmpdump_command(info, resume = false)
      resume_option = resume ? '-e' : ''
      "\
        rtmpdump \
          -q \
          -r #{Shellwords.escape(info[:rtmp_url])} \
          -o #{Shellwords.escape(info[:file_path])} \
          -C S:#{Shellwords.escape(info[:ticket])} \
          --playpath mp4:#{Shellwords.escape(info[:content])} \
          --app #{Shellwords.escape(info[:app])} \
          #{resume_option} \
        2>&1"
    end

    def filepath(live)
      date = live.opens_at.strftime('%Y_%m_%d')
      title = "#{date}_#{live.title}"
      Main::file_path_working_base(CH_NAME, title)
    end
  end
end
