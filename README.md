# Dropbox vs Google Drive - measuring realtime synchronization performance

Following a migration from Dropbox to Google Drive for [my team at Ably Realtime](https://www.ably.io/about/team) in Jan 2018, I noticed that following the migration, files were often out of sync and updates felt sluggish across the board. Whilst the liveness of content is certainly not the only factor in choosing the right cloud based drive solution, I believe that when an online service's user experience lets you down (unreliable sync, slow etc), then you can quickly lose trust in the product. I've seen this first hand now as our team has progressively resorted to emailing files to each other or sharing them on Slack.

Given latencies significantly impact user experience for products where people are collaborating, and as far as I can tell no one yet has measured performance of Dropbox vs Google from a latency perspective, I took it upon myself to compare the two products in a reasonably scientific and reproduceable way.

## Summary of findings

* Dropbox is fast (typically 0.5 to 2s to sync a change). Everything feels like it's happening in real time, and it just works, every time. I've identified lots of technical ways they can improve further and significantly reduce their infrastructure costs. However, in spite of opportunities they have to improve, I have to admit their solution is very good.
* Google Drive & the Google Drive File Stream service is very slow, unreliable, and has lots of synchronization issues. Latencies to update changes vary immensely (from 1s to 2 minutes) with an average of around 45s. Worse still, their are fundamental issues with their synchronization using their Google Drive File Stream product meaning you cannot rely on your files to be in sync, ever.

# Dropbox Performance Tests

Summary of results:

* Average latencies range from 0.5s to 2s for the web interface to reflect changes made via the Dropbox API.
* At present, I am not measuring the time it takes for a file to sync to a local folder. I will work on that next.

##  Setup

* Before you can run the tests, you will need to get an access token from Dropbox. Go to the [Dropbox developers section](https://www.dropbox.com/developers) and login, then go to "My apps", and select your application or create one if you haven't done so yet. Once you are viewing your app, look for the "Generate" button under "Generated access token" and generate a new token. Save this access token in `dropbox_config.json` in the root of this repo. See an example JSON config file at [./dropbox_config.json.example](./dropbox_config.json.example)
* Use bundler to install the required Gem dependencies with `bundle install`

## Running the tests

Run [`ruby dropbox.rb`](./dropbox.rb). When prompted to open a browser, respond with `y` and then paste the Javascript provided (which is automatically added to your clipboard) into the dev console so that web sync latencies can be measured.

## Dropbox Tech Notes

### Transports

Dropbox relies on a long poll mechanism to receive notifications of updates. In all likelihood the system behind this feature for apps is probably very similar to the API they offer customers to programatically get a feed of updates, see https://www.dropbox.com/developers/documentation/http/documentation#files-list_folder-longpoll (Drobox also support Webhooks https://www.dropbox.com/developers/reference/webhooks).

Each long poll HTTP/1.1 request is a `POST` request to `https://bolt.dropbox.com/2/notify/subscribe` with a significant POST payload as follows:

```json
{
   "channel_states":[
      {
         "channel_id":{
            "app_id":"sfj",
            "unique_id":"63098240"
         },
         "revision":"13075",
         "token":"{{OBFUSCATED}}"
      },
      {
         "channel_id":{
            "app_id":"sfj",
            "unique_id":"2712962"
         },
         "revision":"1039486140",
         "token":"{{OBFUSCATED}}"
      },
      .... around 48 of these channel_states ...
      {
         "channel_id":{
            "app_id":"sfj",
            "unique_id":"1229659005"
         },
         "revision":"1",
         "token":"{{OBFUSCATED}}"
      }
   ]
}
```

In response, the following payload is returned if a change occurs (or the request is sent `{}` and closed if there is no activity for roughly 40s):

```
{
   "channel_states":[
      {
         "channel_id":{
            "app_id":"sfj",
            "unique_id":"2712962"
         },
         "revision":"1039486141",
         "token":"{{OBFUSCATED}}"
      }
   ]
}
```

And this in turn triggers a lot of HTTP requests:

* `GET https://www.dropbox.com/update/list_dir` (9.1KB)
* `POST https://www.dropbox.com/share_ajax/shared_with` (2.0KB)
* `POST https://www.dropbox.com/sm/get_token_info` (1.7KB)
* `POST https://www.dropbox.com/2/sharing/list_file_members/batch` (0.5KB)
* `POST https://www.dropbox.com/file_activity/comment_status_batch` (1.8KB)
* `POST https://www.dropbox.com/unity_connection_log` (1.6KB)
* `POST https://www.dropbox.com/starred/get_status` (1.8KB)
* And of course a new long poll `OPTIONS https://bolt.dropbox.com/2/notify/subscribe` and `POST https://bolt.dropbox.com/2/notify/subscribe` (0.2KB)

So a total 9 requests and 18.7KB ingress, and a fair chunk egress given the `POST` body can grow quite large.

### Performance

* Dropbox is noticeably speedy. It was so fast that I had to rewrite some of the code I had written as I was measuring time from completed upload until when it appears in the UI. Sometimes files were appearing in the UI before the HTTP API upload request had completed!
* In spite of the fact that Dropbox is faster, the inefficiencies are incredible. A single file change, that should at best be in the KB range, results in 9 HTTP/1.1 requests and circa 20KB of traffix. Using a smarter duplexed transport such as Websockets would allow the Dropbox client to efficiently communicate what it is listening for, and simply get the updates it needs. According to stats from Aug 2016, 1.2 billion files are uploaded to Dropbox every day, which I assume would result in at least twice that many interface updates (multiple tabs, multiple devices, sharing, changes other than uploads).  If each update results in 19KB more traffic than is necessary, that is a staggering 45TB a day or 1.4 Petabytes per month.  Assuming that's an average bandwidth cost of $0.10 per GB, this inefficiency from just a bandwidth perspective amounts to circa $1.5m per year, not accounting for the hardware costs.
* Long polling is just inefficient and there is little excuse to use this approach in 2018. Dropbox reportedly has half a billion users, which assuming one in five is connected at any point in time, this would result in 150 million new long poll HTTP requests per minute. I certainly appreciate that the underlying TCP/IP connection is reused with HTTP keep-alives, but regardless, this approach of effectively polling every 40s instead of waiting for updates must cost Dropbox a considerable amount of money and significantly complicate their stack.

### Other

Dropbox appear to have an odd dependency that is trying to open Websocket connections to `localhost`, I can only assume that's not intentional and someone's left some debugging code in the production codebase.
`web_socket-vflPfL4KL.ts:37 WebSocket connection to 'ws://127.0.0.1:17602/ws' failed: Error in connection establishment: net::ERR_CONNECTION_REFUSED`

# Google Drive Performance Tests

Summary of results:

* Average latency across my tests range from 15s to 30s for the web interface to reflect changes made to the Google Drive via the API.
* At present, I am not measuring the time it takes for a file to sync to a local folder using Google Drive File Stream as the time it takes ranges from hours to days. Files added locally to "Google Drive" appear in the web version within around 15 seconds, however files uploaded to the Google Drive web version seemingly never get downloaded by Google Drive File Stream. [See below for the details on Google not resolving this and recommending that Google Drive File Stream is no longer used](#google-drive-file-stream-download-problem).

##  Setup

* Before you can run the tests, you will need to authenticate with Google Drive. Follow the [google-drive-ruby Gem instructions](https://github.com/gimite/google-drive-ruby/blob/master/doc/authorization.md#on-behalf-of-you-command-line-authorization), with the the exception that you should create a file `google_drive_config.json` in the root of this repo (as opposed to the recommended `config.json`). See an example JSON config file at [./google_drive_config.json.example](./google_drive_config.json.example)
* Use bundler to install the required Gem dependencies with `bundle install`

## Running the tests

Run [`ruby google_drive.rb`](./google_drive.rb). When prompted to open a browser, respond with `y` and then paste the Javascript provided (which is automatically added to your clipboard) into the dev console so that web sync latencies can be measured.

## Google Drive File Stream download problem:

After discovering that our team are constantly having issues with local files being grossly out of sync at times, I reached out to Google.  They confirmed a known issue, and I am told to send more info, which I did and was able to easily reproduce the problem of a file being on the web version, but not in the local Google Drive.

From: Google Cloud Support
Date: 6 Feb 2018

Summary:

> Hello Matthew,
> Thank you for replying back.
> I would like to clarify a detail I found interesting. Whenever you mentioned: "...some files on my local drive are out of date, yet if I go to the web version, they are up to date", does this mean that the file information is actually updated locally and in the web? but only the date shows not updated?. If that's the case, we are aware of that situation and our production team is actively working to fix this as soon as possible.
> This known issue is affecting multiple users, where, files are updating and syncing, but only the time/date stamp is not being updated. This is under investigation still, so there is no ETA for the fix for now.
> I would like to know if this is the case, if this is not the case, please provide me the following information:
> - Mac: In finder "Go" > "Go to Folder..." >and enter this, exactly: ~/Library/Application Support/Google/DriveFS/Logs, and provide the latest logs. Provide the file with no number and the 2 files with the highest number, they are called like drive_fs_N.txt (where N is the number of log).
> The case will remain open for now, if you need any additional assistance feel free to contact us back and don't hesitate because we'll gladly assist you.

----

After showing screenshots and providing logs, I told that connectivity issues could be the cause, yet there is no indication of that being a problem and Google Drive File Stream is confirming it's connected and synchronised (but it's not synchronised). Note they now recommend I uninstall and reinstall, which is surprising given I've only had Google Drive File Stream for a few weeks now.

From: Google Cloud Support
Date: 7 Feb 2018

> These type of scenarios are mostly related to connectivity issues, meaning that, in most of these cases, it's a matter of testing to check what could be affecting. Remember that, Drive File Stream encrypts all network traffic and validates host certificates to protect against man-in-the-middle (MITM) attacks and others, so, there are some connectivity settings you need to check first, please see and add the "TruestedRootCertsFile" at https://support.google.com/a/answer/7644837.
> After that, we can try to "clean install " the Drive FS app, although I understood you uninstalled the app before, this time we will delete all the cache information of the app in order to make sure all content will be updated from now on, the only detail is that the files locally synced will be deleted, however, this won't affect files on the web.  These are the needed steps to complete:
> 1. Uninstall the app.
> 2. Go to  Mac: In finder "Go" > "Go to Folder..." >and enter this, exactly: ~/Library/Application Support/Google/ and delete the DriveFS folder entirely.
> 3. Install the Drive FS app and log in.

---

Reinstalling didn't fix the issue, so after six email exchanges with Google support where each time I am told I need to send more info (yet it's info they already have such as timestamps, logs, etc). I am finally told that I should stop using Google Drive File Stream and just use the web version :)

From: Google Cloud Support
Date: 1 Mar 2018

> With the information provided I was not able to investigate deeper for now, I understand Drive File Stream keeps causing syncing problems. In this scenario, I would like to take the time to recommend you to consider using our other Sync app called Backup and Sync, which basically is the successor of the old Drive Sync client, there are some new features included, but the syncing process works the same stable way, the only 2 differences between Drive FS and Backup and Sync, are that Drive File Stream live 'streams' your files from the web, so your local storage won't be that affected and also, Drive FS allows you to sync Team Drives. Backup and sync for now will not allow you to sync Team Drives, although, you can continue managing Team Drives from the web, while we improve the Drive File Stream app for all environments.
> You can  compare both sync solutions at https://support.google.com/a/answer/7491633?hl=en. Also, see Backup and sync's options at https://support.google.com/drive/answer/2374987
> Note: As long as you use Backup and sync with a G suite account, the app will be fully supported by us.

## Google Drive Tech Notes

### Transports

Everything is over HTTP2 (in modern supported browsers at least). Whilst HTTP2 is certainly more efficient than HTTP1.1, the approach Google has taken with Google Drive appears to be working from the lowest common denominator in that XHR streaming and HTTP requests are used whcih would work over any version of HTTP.

In order to receive updates about changes in the Drive, the Google Drive app opens an HTTP connection to `cello.client-channel.google.com` which is an HTTP stream similar to below:

`GET https://cello.client-channel.google.com/client-channel/channel/bind?authuser=0&ctype=cello&service=appscommonstorage&gsessionid=...`

```json
18
[[28,["noop"]
]
]
18
[[29,["noop"]
]
]
18
[[30,["noop"]
]
]
520
[[31,[{"p":"{\"1\":{\"1\":{\"1\":{\"1\":1,\"2\":1}},\"4\":\"1520100528401\",\"5\":\"S12\"},\"2\":{\"1\":{\"1\":\"tango_service\",\"2\":\"677AycnWvDv6mS_X\"},\"2\":\"{\\\"1\\\":{\\\"1\\\":{\\\"1\\\":{\\\"1\\\":3,\\\"2\\\":2}},\\\"2\\\":\\\"{{OBFUSCATED}}\\\\u003d\\\\u003d\\\",\\\"4\\\":\\\"1520100528344\\\",\\\"5\\\":\\\"102411029\\\"},\\\"3\\\":{\\\"1\\\":[{\\\"1\\\":{\\\"1\\\":1014,\\\"2\\\":\\\"CHANGELOG\\\"},\\\"2\\\":true,\\\"3\\\":\\\"270237\\\",\\\"6\\\":true}]}}\"}}"}]]
]
18
[[32,["noop"]
]
]
18
[[33,["noop"]
]
]
520
[[34,[{"p":"{\"1\":{\"1\":{\"1\":{\"1\":1,\"2\":1}},\"4\":\"1520100597120\",\"5\":\"S13\"},\"2\":{\"1\":{\"1\":\"tango_service\",\"2\":\"677AycnWvDv6mS_X\"},\"2\":\"{\\\"1\\\":{\\\"1\\\":{\\\"1\\\":{\\\"1\\\":3,\\\"2\\\":2}},\\\"2\\\":\\\"{{OBFUSCATED}}\\\\u003d\\\\u003d\\\",\\\"4\\\":\\\"1520100597061\\\",\\\"5\\\":\\\"102434157\\\"},\\\"3\\\":{\\\"1\\\":[{\\\"1\\\":{\\\"1\\\":1014,\\\"2\\\":\\\"CHANGELOG\\\"},\\\"2\\\":true,\\\"3\\\":\\\"270238\\\",\\\"6\\\":true}]}}\"}}"}]]
]
```

Note:

* The `noop` appears to be a heartbeat to keep the XHR connetion alive.
* The other payloads include a reference that is used to trigger another HTTP request to retrieve the change using a serial number of some sort. The URL from the last patch included a `startChangeId` of `270238` which resulted in a request for everything up to the next serial `GET /drive/v2internal/changes? .... &startChangeId=270239&fields= .... HTTP/1.1`

### Performance & general tech considerations

* It seems odd that Google would use XHR and HTTP requests when there are so many better options for lower latency more lightweight communication (SSE, Websockets etc). It looks to me like Google have been lazy and simply worked to the lowest common denominator i.e. very old browsers, whilst banking on HTTP/2 to save the day. Whilst it does reduce overhead in concurrent requests, there is still a lot more overhead than is necessary and plenty of additional roundtrips.
* It appears Google debounce some of their updates, so batches of updates can come through together. However, it appears they are debouncing the wrong way from a UX perspective i.e. they wait to see if more updates are coming as opposed to updating immediately and the aggregating subsequent updates.
* Writing scripts to interface with their APIs and scrape their code was just painful. Their public APIs are just too complex given what they are doing, and whilst I realise they have no obligation to help developers read their markup and code, it's just painful to see no semantic classes or definitions in their markup. They make their markup and code so obfuscated it's near on impossible to understand in the interests of optimisation, yet the transports to deliver the experience for users are seriously sub-adequate.
* In spite of Google's incredible micro-optimisations, the the Google Drive UI feels very sluggish and I spend a lot of time watching progress spinners.

