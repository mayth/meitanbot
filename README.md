# meitanbot
*There is not meitan.*

@meitanbot - http://twitter.com/meitanbot

## Features
* Automatic posting
    * Create the sentence randomly.
    * Periodical posting
    * Replying
        * Replying to the replies
        * Replying to the tweets that contains specified words
        * Replying to the inquiries of Univ. Tsukuba's class time table
* Capturing tweets with UserStreaming
    * Create tweet-database
    * Create word-database
        * They are used for creating status
* Automatic following/followers management
    * Following the user that follows this account immediately
    * Removing the user that removes this account immediately
    * Periodic check the friends list

## Requirements
* Ruby 1.9 (I developed in 1.9.3-p194)
* MeCab (Japanese Morphological Analyzer)
* MeCab for Ruby binding
    * MeCab: http://mecab.sourceforge.net
* SQLite3
* Twitter API Key

### Required Gems
meitanbot requires these gems.
* sqlite3
* oauth
* json 
* MeCab
    * MeCab can't be installed by `gem`, so install it manually.
Except for MeCab, they can be install by bundler.

## Running Bot

### Install Gems
To install the required gems, do `bundle install` (In addition, I recommend you to specify install directory by --path option to prevent installing gems to globally).

### Add Credential
There is no credential file in this repository, so meitanbot cannot access to Twitter API. Instead of including credential file, there is the template file "credential.yaml.tmpl".
Rename "credential.yaml.tmpl" to "credential.yaml" and fill it.

