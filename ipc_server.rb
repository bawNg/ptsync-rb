module IpcServer
  class << self
    attr_accessor :connection

    def send_packet(*values)
      return unless connection
      packet = "#{values.join("~~~")}\n\n\n"
      #log :magenta, "[IPC] Sending packet: #{packet.inspect}"
      connection.send_data(packet)
    end

    def proxy_events(*event_names)
      event_names.each do |event_name|
        on(event_name) do |*args|
          send_packet(event_name, *args)
        end
      end
    end
  end

  proxy_events :initializing, :updating_client, :checking_for_updates, :checking_files, :hashing_status,
               :request_delete_files_confirmation, :waiting_for_processes, :up_to_date, :restarting

  def post_init
    IpcServer.connection = self
    log "IPC client connected"
    start_application
  end

  def receive_data(data)
    data.split("\n\n\n").each do |line|
      #log "[GUI Client] Said: #{line}"
      on_packet(*line.split('~~~'))
    end
  end

  def on_packet(name, *values)
    case name
      when 'pause'
        on :pause, values.first == 'True'
      when 'confirm_delete_files'
        on :delete_files_confirmation_received, values.first == 'True'
      when 'shutdown'
        send_data "bye\n\n\n"
        close_connection
    end
  end

  def unbind
    IpcServer.connection = nil
    $exiting = true
    EM.stop
  end
end

on :sync_started do |total_bytes|
  IpcServer.send_packet :sync_started, human_readable_byte_size(total_bytes)
end

on :sync_status do |percentage, downloading_count, incomplete_count, downloaded_size, current_speed, time_remaining|
  size = human_readable_byte_size(downloaded_size)
  time_remaining_in_words = time_remaining ? distance_of_time_in_words(time_remaining) : ''
  IpcServer.send_packet :sync_status, percentage, downloading_count, incomplete_count, size, current_speed, time_remaining_in_words
end

on :sync_complete do |downloaded_file_count, duration|
  IpcServer.send_packet :sync_complete, downloaded_file_count, distance_of_time_in_words(duration)
end

on :time_remaining_until_next_check do |seconds|
  IpcServer.send_packet :time_remaining_until_next_check, distance_of_time_in_words(seconds)
end

def check_parent_process
  parent_process = $wmi.ExecQuery("SELECT * FROM win32_process WHERE ProcessId = #{Process.ppid}").each.first
  if parent_process
    parents_parent_pid = parent_process.ParentProcessId
    return if $wmi.ExecQuery("SELECT * FROM win32_process WHERE ProcessId = #{parents_parent_pid}").each.count > 0
    log "Parent processes parent (#{parents_parent_pid}) no longer exists, exiting..."
  else
    log "Parent process (#{Process.ppid}) no longer exists, exiting..."
  end
  $exiting = true
  EM.stop
end

EM.schedule do
  check_parent_process
  EM.add_periodic_timer(0.5) { check_parent_process }
end