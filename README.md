A cross platform NS2 play-tester syncing client written in ruby. Tested to be working on Windows and Linux.

## Getting Started
- If you are using the windows package, first extract it to a location of your choice.
- When you run ptsync_rb for the first time, it will generate a config.yml file and tell you the s3 keys are missing.
- Open the config.yml file in notepad and put in your two s3 keys and the correct path to your local NS2 directory.
- Run ptsync_rb again and leave the console window open until it has completed syncing.

## Windows
Basic options can be set from the config.yml file. If you want to use any of the additional command like options, you can create a shortcut to ptsync which includes these options and use that to launch ptsync. If you do create a shortcut, make sure the working directory is correctly set to the folder you extracted pysync_rb to.

A GUI interface will be added soon.

## Command line options:
            --verbose, -v:   Print extended information
               --once, -o:   Exit after syncing has completed
          --createdir, -c:   Creates the local NS2 directory
           --nodelete, -n:   Ignore additional/removed files
             --delete, -d:   Delete additional files without asking
         --noexcludes, -e:   No not sync the .excludes directory
             --verify, -y:   Verify the integrity of all local files
            --dir, -p <s>:   Local NS2 Directory
    --afterupdate, -a <s>:   Command to run after each update
           --host, -h <s>:   S3 host address
          --idkey, -i <s>:   S3 ID key
      --secretkey, -s <s>:   S3 secret key
         --bucket, -b <s>:   S3 bucket to sync with (default: ns2build)
    --concurrency, -u <i>:   Max concurrent connections (default: 48)
       --maxspeed, -m <i>:   Rough download speed limit in KB/s (default: -1)
               --help, -l:   Show this message