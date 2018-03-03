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

