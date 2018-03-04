#!/usr/bin/env ruby

require 'securerandom'

require 'dropbox_api'

# Web server to listen for timestamps from web interface, using ngrok to get a public interface
require 'clipboard'
require 'http'
require 'ngrok/tunnel'
require 'sinatra/base'

require 'thread'
MUTEX = Mutex.new

PERF_FOLDER = 'DropboxPerfTest'
DRIVE_HOME_FOLDER = '~/Dropbox'
FILE_NAME_PREFIX = 'iteration'

TEST_ID = SecureRandom.hex(3)
WEB_SERVER_PORT = rand(10000) + 10000
TEST_ITERATIONS = 20 # if we test with more files than this, in some cases the file is lazy loaded in the UI so this test never passes without adding a lot more coplexity to the frontend code
TEST_PAUSE_RANGE = 15

WEB_SERVER_STATE = {}
ITERATION_HISTORY = []

class SinatraServer < Sinatra::Base
  set :port, WEB_SERVER_PORT

  get '/ping' do
    puts 'Ping successfully received in web server'
    WEB_SERVER_STATE[:pinged] = true
  end

  get '/ready' do
    headers 'Access-Control-Allow-Origin' => '*'
    WEB_SERVER_STATE[:ready] = true
  end

  get '/sync' do
    headers 'Access-Control-Allow-Origin' => '*'
    MUTEX.synchronize do
      iteration_id = params['fileName'][/^\s*#{FILE_NAME_PREFIX}-(\d+)/, 1]
      timestamp = params['ts'].to_i
      if !iteration_id || !timestamp || (timestamp <= 0)
        puts "Error! Invalid params received on endpoint /sync: #{params}"
      else
        iteration = ITERATION_HISTORY.find { |it| it.fetch(:id) == iteration_id.to_i }
        if !iteration
          puts "Error! Invalid iteration ID #{iteration_id}, missing from ITERATION_HISTORY"
        else
          iteration[:web_sync_at] = Time.at(timestamp.to_f / 1000)
          puts " ✓ Iteration #{iteration_id} synced in web interface #{(iteration.fetch(:web_sync_at).to_f - iteration.fetch(:upload_started_at).to_f).round(2)}s after upload started"
        end
      end
    end
  end
end

puts "Starting a trivial web server on port #{WEB_SERVER_PORT}"
Thread.abort_on_exception = true
sinatra_thread = Thread.new do
  SinatraServer.run!
end

puts 'Punching out of the network and getting a public endpoint from ngrok'
Ngrok::Tunnel.start(addr: "localhost:#{WEB_SERVER_PORT}")
trap('SIGINT') do
  Ngrok::Tunnel.stop
  exit 1
end
puts "Ngrok setup on #{Ngrok::Tunnel.ngrok_url_https}, testing that the web server is responding..."

ping_url = "#{Ngrok::Tunnel.ngrok_url_https}/ping"
ping_response = HTTP.get(ping_url)
if !WEB_SERVER_STATE[:pinged]
  raise "Web server is not accessible from outside. Response from #{ping_url}:\n#{ping_response.inspect}"
end
puts "Web server is now accessible externally at #{Ngrok::Tunnel.ngrok_url_https}"

dropbox_config = File.read(File.expand_path("../dropbox_config.json", __FILE__))
access_token = JSON.parse(dropbox_config).fetch('access_token') { raise 'access_token attribute is missing' }
dropbox_client = DropboxApi::Client.new(access_token)

root = dropbox_client.list_folder('').entries
if root.find { |folder| folder.name == PERF_FOLDER }.nil?
  puts "Creating new folder '#{PERF_FOLDER}' in root"
  dropbox_client.create_folder "/#{PERF_FOLDER}"
end

test_folder_path = "/#{PERF_FOLDER}/#{TEST_ID}"
puts "Creating test folder '#{test_folder_path}'"
dropbox_client.create_folder test_folder_path

puts "Would you like me to open your browser now to the test folder '#{test_folder_path}' automatically? [y/n]"
if gets.chomp.match(/^y/i)
  require 'launchy'
  Launchy.open("https://www.dropbox.com/home#{test_folder_path}")
end

javascript = <<EOM
  (function() {
    let folder = document.querySelector('div.brws-files-view');
    let filesSelector = 'table.mc-table.brws-files-view-list tr.brws-file-row';
    let filesByName = [];

    if (!folder) { throw('Could not find listbox DOM element. Did you run this script before the page rendered?'); }

    /* Ignore existing files, only monitor new ones */
    folder.querySelectorAll(filesSelector).forEach((element) => { filesByName.push(element.innerHTML); });

    let timer = setInterval(() => {
      let files = folder.querySelectorAll(filesSelector);
      files.forEach((element) => {
        let fileName = element.getAttribute('data-filename');
        if (fileName) {
          if (!filesByName.includes(fileName)) {
            let request = new XMLHttpRequest();
            request.open('GET', `#{Ngrok::Tunnel.ngrok_url_https}/sync?fileName=${fileName}&ts=${new Date().getTime()}`);
            request.send();
            filesByName.push(fileName);
            console.log(`Detected new file: '${fileName}' at ${new Date()}`);
          }
        }
      });
    }, 100);

    function stopPerfTimer() {
      if (timer) { clearInterval(timer); }
      console.log('Stopped performance timer.');
    };
    if (document.stopPerfTimer) { document.stopPerfTimer(); }
    document.stopPerfTimer = stopPerfTimer;

    let request = new XMLHttpRequest();
    request.open('GET', `#{Ngrok::Tunnel.ngrok_url_https}/ready`);
    request.send();

    console.log('Now monitoring files and their create timestamps. Run `document.stopPerfTimer()` when done');
  })();
EOM

puts "Run this Javascript in your browser console for the Dropbox web view of the folder so we can track how long it takes for the files to sync:\n\n\n"
puts javascript
Clipboard.copy javascript

puts "\n\nP.S. We just copied the Javascript to your clipboard as a convenience"
print "\n\nWaiting for you to paste in the Javascript..."
while !WEB_SERVER_STATE[:ready]
  print '.'
  $stdout.flush
  sleep 2
end

puts "\n\nTest will now commence by uploading #{TEST_ITERATIONS} files to Dropbox"

TEST_ITERATIONS.times do |index|
  iteration_data = { id: index, upload_started_at: Time.now }
  ITERATION_HISTORY << iteration_data
  dropbox_client.upload "#{test_folder_path}/#{FILE_NAME_PREFIX}-#{index}.txt", "<empty>"
  iteration_data[:upload_completed_at] = Time.now
  next_pause = rand(TEST_PAUSE_RANGE).round
  puts "Uploaded test file with index #{index} successfully in #{(iteration_data.fetch(:upload_completed_at).to_f - iteration_data.fetch(:upload_started_at).to_f).round(2)}s. Pausing #{next_pause}s before next upload."
  sleep next_pause
end

puts "\n\nWaiting for files to be synchronized..."
sleep 1 while (ITERATION_HISTORY.length != TEST_ITERATIONS) || !ITERATION_HISTORY.all? { |iteration| iteration[:web_sync_at] }

puts "\n\nDropbox performance test complete:\n\n"
puts "#{ITERATION_HISTORY.first.keys.join(',')},web_sync_duration_from_upload_start,web_sync_duration_from_upload_complete"
total_sync_time_from_start = 0
total_sync_time_from_completed = 0
ITERATION_HISTORY.each do |iteration|
  web_sync_duration_from_completed = iteration.fetch(:web_sync_at).to_f - iteration.fetch(:upload_completed_at).to_f
  web_sync_duration_from_start = iteration.fetch(:web_sync_at).to_f - iteration.fetch(:upload_started_at).to_f
  total_sync_time_from_start += web_sync_duration_from_start
  total_sync_time_from_completed += web_sync_duration_from_completed
  puts (iteration.values + [web_sync_duration_from_start, web_sync_duration_from_completed]).join(',')
end

puts "\n"
puts "Average web sync time from start of upload: #{(total_sync_time_from_start / TEST_ITERATIONS).round(2)}s"
puts "Average web sync time from upload complete: #{(total_sync_time_from_completed / TEST_ITERATIONS).round(2)}s"
