A cross platform NS2 play-tester syncing client written in ruby. Tested to be working on Windows and Linux.

## Getting Started
- When you run ptsync_rb for the first time, it will generate a config.yml file and tell you the s3 keys are missing.
- Open the config.yml file in notepad and put in your two s3 keys and the correct path to your local NS2 directory.
- Run ptsync_rb again and leave the console window open until it has completed syncing.

### Windows
- Extract the windows package rar file into a directory of your choice (outside of your NS2 directory)
- Basic options can be set from the config.yml file.
- If you want to use any of the additional command like options, you can create a shortcut to ptsync which includes these options and use that to launch ptsync. If you do create a shortcut, make sure the working directory is correctly set to the folder you extracted pysync_rb to.

### Linux
- Make sure you have ruby 1.9.x installed, ptsync-rb has been built and tested with ruby 1.9.3
- Install Git if you do not already have it with `sudo apt-get install git-core`
- Install dependencies for building native extensions with `sudo apt-get install ruby1.9.1-dev libxml2-dev zlib1g-dev`
- Change to a directory of your choice and use `git clone https://github.com/bawNg/ptsync-rb.git`
- Use `cd ptsync-rb` to change to the sync clients directory
- Run `sudo gem install bundler` if you do not already have the bundler gem installed
- Run the `bundle` command to download and install all dependencies for ptsync-rb
- Run `ruby ./ptsync.rb` to start the sync client. You can use `ruby ./ptsync.rb --help` to list all available options.


## Command line options:
            --verbose, -v:   Print extended information
              --debug, -g:   Print detailed debug information
               --once, -o:   Exit after syncing has completed
          --createdir, -c:   Create the local NS2 directory
           --nodelete, -n:   Ignore additional/removed files
             --delete, -d:   Delete additional files without asking
         --noexcludes, -e:   Do not sync the .excludes directory
      --ignorerunning, -r:   Ignore any running NS2 applications
             --verify, -y:   Verify the integrity of all local files
            --dir, -p <s>:   Local NS2 directory
    --afterupdate, -a <s>:   Command to run after each update
           --host, -h <s>:   S3 host address
          --idkey, -i <s>:   S3 ID key
      --secretkey, -s <s>:   S3 secret key
         --bucket, -b <s>:   S3 bucket to sync with (default: ns2build)
    --concurrency, -u <i>:   Max concurrent connections (default: 48)
       --maxspeed, -m <i>:   Rough download speed limit in KB/s (default: -1)
               --help, -l:   Show this message