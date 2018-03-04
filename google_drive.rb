#!/usr/bin/env ruby

require 'fileutils'
require 'securerandom'

# Uses Gem https://github.com/gimite/google-drive-ruby for reading/writing files to Google Drive
# The official Google SDK is overly complicated for a trivial example like this
require 'google_drive'

# Web server to listen for timestamps from web interface, using ngrok to get a public interface
require 'clipboard'
require 'http'
require 'ngrok/tunnel'
require 'sinatra/base'

require 'thread'
MUTEX = Mutex.new

PERF_FOLDER = 'GoogleDrivePerfTest'
DRIVE_HOME_FOLDER = '~/Google Drive File Stream/My Drive'
FILE_NAME_PREFIX = 'iteration'

TEST_ID = SecureRandom.hex(3)
WEB_SERVER_PORT = rand(10000) + 10000
TEST_ITERATIONS = 20 # if we test with more files than this, in some cases the file is lazy loaded in the UI so this test never passes without adding a lot more coplexity to the frontend code
TEST_PAUSE_RANGE = 15

WEB_SERVER_STATE = {}
ITERATION_HISTORY = []

total_sync_time_from_start = Hash.new { |hsh, key| hsh[key] = 0 }
total_sync_time_from_completed = Hash.new { |hsh, key| hsh[key] = 0 }

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

  get '/empty' do
    headers 'Access-Control-Allow-Origin' => '*'
    WEB_SERVER_STATE[:empty] = true
  end

  get '/sync' do
    headers 'Access-Control-Allow-Origin' => '*'
    WEB_SERVER_STATE[:empty] = false
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

# Creates a Google Drive session. This will prompt the credential via command line for the
# first time and save it to config.json file for later usages.
# See this document to learn how to create config.json:
# https://github.com/gimite/google-drive-ruby/blob/master/doc/authorization.md
drive_session = GoogleDrive::Session.from_config('google_drive_config.json')

root = drive_session.root_collection
perf_collection = root.subcollections.find { |folder| folder.title == PERF_FOLDER }
if perf_collection.nil?
  puts "Creating new folder '#{PERF_FOLDER}' in root"
  perf_collection = root.create_subcollection(PERF_FOLDER)
end

test_folder_path = "#{PERF_FOLDER}/#{TEST_ID}"
puts "Creating test folder '#{test_folder_path}'"
test_collection = perf_collection.create_subcollection(TEST_ID)

puts "Would you like me to open your browser now to the test folder '#{test_folder_path}' automatically? [y/n]"
if gets.chomp.match(/^y/i)
  require 'launchy'
  Launchy.open("https://drive.google.com/drive/u/0/folders/#{test_collection.id}")
end

javascript = <<EOM
  (function() {
    let visibleRootFolder = () => { return Array.from(document.querySelectorAll('div[role=main]')).find((elem) => { return elem.style.display !== 'none'; }); };
    let folder = () => { return visibleRootFolder().querySelector('div[role="presentation"] div[role="listbox"]'); }
    let filesSelector = 'div[data-target=doc] > div > div > div > div > div[aria-label] span[data-is-doc-name=true]';
    let filesByName = [];

    let getFn = (path) => {
      let request = new XMLHttpRequest();
      request.open('GET', `#{Ngrok::Tunnel.ngrok_url_https}/${path}`);
      request.send();
    };

    if (!folder()) { throw('Could not find listbox DOM element. Did you run this script before the page rendered?'); }

    /* Ignore existing files, only monitor new ones */
    folder().querySelectorAll(filesSelector).forEach((element) => { filesByName.push(element.innerHTML); });

    let timer = setInterval(() => {
      let files = folder().querySelectorAll(filesSelector);
      files.forEach((element) => {
        let fileName = element.innerHTML;
        if (fileName) {
          if (!filesByName.includes(fileName)) {
            getFn(`sync?fileName=${fileName}&ts=${new Date().getTime()}`);
            filesByName.push(fileName);
            console.log(`Detected new file: '${fileName}' at ${new Date()}`);
          }
        }
      });
      if ((files.length === 0) && (filesByName.length !== 0)) {
        filesByName = [];
        getFn('empty');
      }
    }, 100);

    function stopPerfTimer() {
      if (timer) { clearInterval(timer); }
      console.log('Stopped performance timer.');
    };
    if (document.stopPerfTimer) { document.stopPerfTimer(); }
    document.stopPerfTimer = stopPerfTimer;

    getFn('ready');
    console.log('Now monitoring files and their create timestamps. Run `document.stopPerfTimer()` when done');
  })();
EOM

puts "Run this Javascript in your browser console for the Google Drive web view of the folder so we can track how long it takes for the files to sync:\n\n\n"
puts javascript
Clipboard.copy javascript

puts "\n\nP.S. We just copied the Javascript to your clipboard as a convenience"
print "\n\nWaiting for you to paste in the Javascript..."
while !WEB_SERVER_STATE[:ready]
  print '.'
  $stdout.flush
  sleep 2
end

puts "\n\nFirst test will now commence by uploading #{TEST_ITERATIONS} files to Google Drive via the API and we'll measure how long it takes for those files to appear in the web view."

TEST_ITERATIONS.times do |index|
  iteration_data = { id: index, upload_started_at: Time.now }
  ITERATION_HISTORY << iteration_data
  test_collection.upload_from_string("<empty>", "#{FILE_NAME_PREFIX}-#{index}.txt", :content_type => "text/plain")
  MUTEX.synchronize { iteration_data[:upload_completed_at] = Time.now }
  next_pause = rand(TEST_PAUSE_RANGE).round
  puts "Uploaded test file with index #{index} successfully in #{(iteration_data.fetch(:upload_completed_at).to_f - iteration_data.fetch(:upload_started_at).to_f).round(2)}s. Pausing #{next_pause}s before next upload."
  sleep next_pause
end

puts "\n\nWaiting for files to be synchronized..."
sleep 1 while (ITERATION_HISTORY.length != TEST_ITERATIONS) || !ITERATION_HISTORY.all? { |iteration| iteration[:web_sync_at] }

puts "\n\nGoogle Drive API to web performance test complete:\n\n"
puts "#{ITERATION_HISTORY.first.keys.join(',')},web_sync_duration_from_upload_start,web_sync_duration_from_upload_complete"

ITERATION_HISTORY.each do |iteration|
  web_sync_duration_from_completed = iteration.fetch(:web_sync_at).to_f - iteration.fetch(:upload_completed_at).to_f
  web_sync_duration_from_start = iteration.fetch(:web_sync_at).to_f - iteration.fetch(:upload_started_at).to_f
  total_sync_time_from_start[:api_to_web] += web_sync_duration_from_start
  total_sync_time_from_completed[:api_to_web] += web_sync_duration_from_completed
  puts (iteration.values + [web_sync_duration_from_start, web_sync_duration_from_completed]).join(',')
end

print "\n\nNow deleting the uploaded files to free up space in the UI for the next test."
test_collection = perf_collection.subcollection_by_title(TEST_ID)
test_collection.files.each do |file|
  file.delete
  print '.'
end
print "\nAll #{test_collection.files.length} files deleted. \nWaiting for confirmation from the browser script that the Web UI is now clear (make sure the window has focus and don't reload!)."
while !WEB_SERVER_STATE[:empty]
  print '.'
  $stdout.flush
  sleep 2
end

puts "\n\n\nSecond test will now commence by writing #{TEST_ITERATIONS} files to the local drive and we'll measure how long it takes for those files to appear in the web view."

local_test_folder_path = File.join(File.expand_path(DRIVE_HOME_FOLDER), "Local.#{test_folder_path}")
FileUtils.mkdir_p local_test_folder_path

puts "Note: As Google Drive is not syncing from web to local at all at present, we in fact have to use a new local folder that will sync up to Google Drive cloud. Please close your Google Drive Tab now."
puts "Press enter when done and we will open a new tab for you."
gets

WEB_SERVER_STATE[:ready] = false
Launchy.open("https://drive.google.com/drive/u/0")

puts "Now navigate to the '#{"Local.#{test_folder_path}"}' folder in Google Drive."
puts "Have you got the '#{"Local.#{test_folder_path}"}' folder open in Google Drive in your browser? [y/n]"
if !gets.chomp.match(/^y/i)
  raise 'Cannot proceed without the tab manually opened'
end

puts "\nNow run this Javascript in your browser console for the Google Drive web view of the folder so we can track how long it takes for the files to sync:\n\n\n"
puts javascript
Clipboard.copy javascript

puts "\n\nP.S. We just copied the Javascript to your clipboard as a convenience"
print "\n\nWaiting for you to paste in the Javascript..."
while !WEB_SERVER_STATE[:ready]
  print '.'
  $stdout.flush
  sleep 2
end

test_offset = TEST_ITERATIONS
TEST_ITERATIONS.times do |times_index|
  index = times_index + test_offset
  iteration_data = { id: index, upload_started_at: Time.now }
  ITERATION_HISTORY << iteration_data
  File.write File.expand_path("#{FILE_NAME_PREFIX}-#{index}.txt", local_test_folder_path), '<empty>'
  MUTEX.synchronize { iteration_data[:upload_completed_at] = Time.now }
  next_pause = rand(TEST_PAUSE_RANGE).round
  puts "Created test file with index #{index} successfully in #{local_test_folder_path}. Pausing #{next_pause}s before next file creation."
  sleep next_pause
end

puts "\n\nWaiting for files to be synchronized..."
sleep 1 while (ITERATION_HISTORY.length != (TEST_ITERATIONS + test_offset)) || !ITERATION_HISTORY.all? { |iteration| iteration[:web_sync_at] }

puts "\n\nLocal drive file to web performance test complete:\n\n"
puts "#{ITERATION_HISTORY.first.keys.join(',')},web_sync_duration_from_upload_start,web_sync_duration_from_upload_complete"

ITERATION_HISTORY.each do |iteration|
  next if iteration.fetch(:id) < test_offset
  web_sync_duration_from_completed = iteration.fetch(:web_sync_at).to_f - iteration.fetch(:upload_completed_at).to_f
  web_sync_duration_from_start = iteration.fetch(:web_sync_at).to_f - iteration.fetch(:upload_started_at).to_f
  total_sync_time_from_start[:local_drive_to_web] += web_sync_duration_from_start
  total_sync_time_from_completed[:local_drive_to_web] += web_sync_duration_from_completed
  puts (iteration.values + [web_sync_duration_from_start, web_sync_duration_from_completed]).join(',')
end

puts "\n--- GOOGLE DRIVE ---\n\n"
puts "Average web sync time from start of API upload: #{(total_sync_time_from_start[:api_to_web] / TEST_ITERATIONS).round(2)}s"
puts "Average web sync time from API upload complete: #{(total_sync_time_from_completed[:api_to_web] / TEST_ITERATIONS).round(2)}s"

puts "\n"
puts "Average web sync time from local drive write: #{(total_sync_time_from_completed[:local_drive_to_web] / TEST_ITERATIONS).round(2)}s"
