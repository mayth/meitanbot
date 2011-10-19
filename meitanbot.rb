#coding:utf-8

require 'net/https'
require 'oauth'
require 'json'
require 'yaml'
require 'twitter'
require 'thread'

class MeitanBot
  # YAML-File including credential data
  CREDENTIAL_FILE = 'credential.yaml'
  # Text for replying "not-meitan"
  NOTMEITAN_FILE = 'notmeitan.txt'
  # Text for replying mentions
  MENTION_FILE = 'reply_mention.txt'
  # Text for replying "C#"
  REPLY_CSHARP_FILE = 'reply_csharp.txt'
  # Text for replying morning greeting
  REPLY_MORNING_FILE = 'reply_morning.txt'
  # HTTPS Certificate file
  HTTPS_CA_FILE = 'certificate.crt'

  # Screen name of this bot
  SCREEN_NAME = 'meitanbot'
  # User-Agent
  BOT_USER_AGENT = 'Nowhere-type Meitan bot 1.0 by @maytheplic'
  # Max retrying count when disconnected from Twitter or exception was thrown
  MAX_RETRY_COUNT = 5
  # Twitter ID of the owner of this bot
  OWNER_ID = 246793872
  # Twitter ID of this bot
  MY_ID = 323080975
  # Twitter IDs to ignore
  IGNORE_IDS = [MY_ID]
  # Sleeping time when Twitter API returns 403(Forbidden)
  SLEEP_WHEN_FORBIDDEN = 300

  # Initialize this class.
  def initialize
    # Queue for threads
    @post_queue = Queue.new
    @meitan_queue = Queue.new
    @reply_queue = Queue.new
    @csharp_queue = Queue.new
    @morning_greeting_queue = Queue.new
    @retweet_queue = Queue.new
    @event_queue = Queue.new
    @message_queue = Queue.new

    # fields
    @is_ignore_owner = true
    @is_enabled_posting = true

    # load credential
    open(CREDENTIAL_FILE) do |file|
      @credential = YAML.load(file)
    end

    @consumer = OAuth::Consumer.new(
      @credential['consumer_key'],
      @credential['consumer_secret']
    )
    
    @access_token = OAuth::AccessToken.new(
      @consumer,
      @credential['access_token'],
      @credential['access_token_secret']
    )

    read_post_text_files
  end

  # Connect to Twitter UserStream
  def connect
    uri = URI.parse("https://userstream.twitter.com/2/user.json?track=#{SCREEN_NAME}")

    https = Net::HTTP.new(uri.host, uri.port)
    https.use_ssl = true
    https.ca_file = HTTPS_CA_FILE
    https.verify_mode = OpenSSL::SSL::VERIFY_PEER
    https.verify_depth = 5

    https.start do |https|
      request = Net::HTTP::Get.new(uri.request_uri)
      request["User-Agent"] = BOT_USER_AGENT
      request.oauth!(https, @consumer, @access_token)

      buf = ""
      https.request(request) do |response|
        response.read_body do |chunk|
          buf << chunk
          while ((line = buf[/.+?(\r\n)+/m]) != nil)
            begin
              buf.sub!(line, "")
              line.strip!
              status = JSON.parse(line)
            rescue
              break
            end

            yield status
          end
        end
      end
    end
  end

  # Start bot
  def run
    puts 'run!'

    # ThreadGroup for the thread that can tweet
    @tweeter_threads = ThreadGroup.new

    post_thread = Thread.new do
      puts 'post thread start'
      loop do
        json = @post_queue.pop
        user = json['user']
        if json['text'].include?('#meitanbot') and user['id'] == OWNER_ID
          puts 'Owner update the status including meitanbot hash-tag.'
          @retweet_queue.push json
        end
        unless IGNORE_IDS.include?(user['id']) or (@is_ignore_owner and user['id'] == OWNER_ID)
          if /め[　 ーえぇ]*い[　 ーいぃ]*た[　 ーあぁ]*ん/ =~ json['text'] or json['text'].include?('#mei_tan')
            puts "meitan detected. reply to #{json['id']}"
            @meitan_queue.push json
          elsif /^@#{SCREEN_NAME}/ =~ json['text']
            puts "reply detected. reply to #{json['id']}"
            @reply_queue.push json
          elsif /.*C#.*/ =~ json['text']
            puts "C# detected. reply to #{json['id']}"
            @csharp_queue.push json
          elsif /(おはよ[うー]{0,1}(ございます|ございました){0,1})|(むくり)|(^mkr$)/ =~ json['text']
            puts "morning greeting detected. reply to #{json['id']}"
            @morning_greeting_queue.push json
          end
        else
          puts "ignore list includes id:#{user['id']}. ignored."
        end
      end
    end
    @tweeter_threads.add post_thread

    sleep 1

    meitan_thread = Thread.new do
      puts 'meitan thread start'
      loop do
        json = @meitan_queue.pop
        res = reply_meitan(json['user']['screen_name'], json['id'])
        if res === Net::HTTPForbidden
          puts "returned 403 Forbidden. Considering status duplicate, or rate limit."
          puts "meitan thread sleeps #{SLEEP_WHEN_FORBIDDEN} sec"
          sleep SLEEP_WHEN_FORBIDDEN
        end
      end
    end
    @tweeter_threads.add meitan_thread

    sleep 1

    reply_thread = Thread.new do
      puts 'reply thread start'
      loop do
        json = @reply_queue.pop
        res = reply_mention(json['user']['screen_name'], json['id'])
        if res === Net::HTTPForbidden
          puts "returned 403 Forbidden. Considering status duplicate, or rate limit."
          puts "reply thread sleeps #{SLEEP_WHEN_FORBIDDEN} sec"
          sleep SLEEP_WHEN_FORBIDDEN
        end
      end
    end
    @tweeter_threads.add reply_thread

    sleep 1

    csharp_thread = Thread.new do
      puts 'csharp thread start'
      loop do
        json = @reply_queue.pop
        res = reply_csharp(json['user']['screen_name'], json['id'])
        if res === Net::HTTPForbidden
          puts "returned 403 Forbidden. Considering status duplicate, or rate limit."
          puts "csharp thread sleeps #{SLEEP_WHEN_FORBIDDEN} sec"
          sleep SLEEP_WHEN_FORBIDDEN
        end
      end
    end
    @tweeter_threads.add csharp_thread
    
    sleep 1
    
    morning_greeting_thread = Thread.new do
      puts 'morning greeting thread start'
      loop do
        json = @morning_greeting_queue.pop
        res = reply_morning(json['user']['screen_name'], json['id'])
        if res === Net::HTTPForbidden
          puts "returned 403 Forbidden. Considering status duplicate, or rate limit."
          puts "morning greeting thread sleeps #{SLEEP_WHEN_FORBIDDEN} sec"
          sleep SLEEP_WHEN_FORBIDDEN
        end
      end
    end
    
    sleep 1
    
    retweet_thread = Thread.new do
      puts 'retweet thread start'
      loop do
        json = @retweet_queue.pop
        res = retweet(json['id'])
        if res === Net::HTTPForbidden
          puts "returned 403 Forbidden. Considering status duplicate, or rate limit."
          puts "retweet thread sleeps #{SLEEP_WHEN_FORBIDDEN} sec"
          sleep SLEEP_WHEN_FORBIDDEN
        end
      end
    end
    @tweeter_threads.add retweet_thread
    
    sleep 1

    event_thread = Thread.new do
      puts 'event thread start'
      loop do
        json = @event_queue.pop
        case json['event'].to_sym
        when :follow
          puts "new follower: #{json['source']}"
          follow_user json['source']['id']
        end
      end
    end

    sleep 1

    message_thread = Thread.new do
      puts 'message thread start'
      loop do
        json = @message_queue.pop
        sender = json['direct_message']['sender']
        text = json['direct_message']['text'].strip
        if sender['id'] == OWNER_ID && text.start_with?('cmd ')
          puts "Received Command Message"
          cmd_ary = text.split(3)
          control_command(cmd_ary[1].to_sym, cmd_ary[2].split)
        end
      end # end of loop do ...
    end # end of Thread.new do ...

    sleep 1

    time_signal_thread = Thread.new do
      puts 'time signal thread start'
      loop do
        t = Time.now.getutc
        if t.min == 0
          loop do
            t = Time.now.getutc
            h = t.hour + 7
            post_time_signal h >= 24 ? h - 24 : h
            sleep(60 * 60) # sleep 1 hour
          end
        end
      end
    end
    @tweeter_threads.add time_signal_thread

    sleep 1

    friendship_check_thread = Thread.new do
      puts 'friendship check thread start'
      loop do
        follow_unfollowing_user
        remove_removed_user
        sleep(60 * 60 * 12) # sleep half a day
      end
    end

    sleep 1

    receiver_thread = Thread.new do
      puts "receiver thread start"
      retry_count = 0
      loop do
        begin
          connect do |json|
            if json['text']
              @post_queue.push json
            elsif json['event']
              @event_queue.push json
            elsif json['direct_message']
              @message_queue.push json
            end
          end
        rescue Timeout::Error, StandardError
          if (retry_count < MAX_RETRY_COUNT)
            retry_count += 1
            puts $!
            puts("Connection to Twitter is disconnected. Re-connect. retry:#{retry_count}")
          else
            puts("Retry Limit. Terminate bot.")
            exit
          end
        end
      end
    end
    
    sleep 1

    tweet_greeting
    
    puts 'startup complete.'
  end # end of run method

  # Tweet the greeting post when bot is started.
  def tweet_greeting
    puts "greeting"
    post 'starting meitan-bot. Hello! ' + Time.now.strftime("%X")
  end

  # Tweet the time signal post.
  def post_time_signal(hour)
    puts "time signal: #{hour}"
    post "#{hour}時(TST)をお知らせします。"
  end

  # Tweet "I'm not meitan!"
  def reply_meitan(reply_screen_name, in_reply_to_id)
    puts "replying to meitan"
    post_reply("@#{reply_screen_name} #{random_notmeitan}", in_reply_to_id)
  end

  # Reply to reply to me
  def reply_mention(reply_screen_name, in_reply_to_id)
    puts "replying to mention"
    post_reply("@#{reply_screen_name} #{random_mention}", in_reply_to_id)
  end

  # Reply to the post containing "C#"
  def reply_csharp(reply_screen_name, in_reply_to_id)
    puts "replying to csharp"
    post_reply("@#{reply_screen_name} #{random_csharp}", in_reply_to_id)
  end
  
  def reply_morning(reply_screen_name, in_reply_to_id)
    puts 'replying to morning greeting'
    post_reply("@#{reply_screen_name} #{random_morning}", in_reply_to_id)
  end

  # Reply
  def post_reply(status, in_reply_to_id)
    if @is_enabled_posting
      puts "replying"
      @access_token.post('https://api.twitter.com/1/statuses/update.json',
        'status' => status,
        'in_reply_to_status_id' => in_reply_to_id)
    else
      puts "posting function is now disabled because @is_enabled_posting is false."
    end
  end

  # Post
  def post(status)
    if @is_enabled_posting
      puts "posting"
      res = @access_token.post('https://api.twitter.com/1/statuses/update.json',
        'status' => status)
    else
      puts "posting function is now disabled because @is_enabled_posting is false."
    end
  end

  # Send Direct Message
  def send_direct_message(text, recipient_id)
    puts "Sending Direct Message"
    @access_token.post('https://api.twitter.com/1/direct_messages/new.json',
      'user_id' => recipient_id,
      'text' => text)
  end

  # Follow the user
  def follow_user(id)
    unless id == MY_ID
      puts "following user: #{id}"
      @access_token.post('https://api.twitter.com/1/friendships/create.json',
        'user_id' => id)
    end
  end

  # Remove the user
  def remove_user(id)
    unless id == MY_ID
      puts "removing user: #{id}"
      @access_token.post('https://api.twitter.com/1/friendships/destroy.json',
        'user_id' => id)
    end
  end

  # Retweet the status
  def retweet(id)
    puts "retweeting status-id: #{id}"
    @access_token.post("https://api.twitter.com/1/statuses/retweet/#{id}.json")
  end

  # Get "not-meitan" text
  def random_notmeitan
    @notmeitan_text.sample
  end

  # Get the replying text
  def random_mention
    @reply_mention_text.sample
  end

  # Get the replying for the status containing "C#"
  def random_csharp
    @reply_csharp_text.sample
  end

  # Get the replying text for the status containing morning greeting
  def random_morning
    @reply_morning_text.sample
  end

  # Get followers
  def get_followers(cursor = '-1')
    puts "get_followers: cursor=#{cursor}"
    result = []
    if (cursor != '0')
      res = @access_token.get('https://api.twitter.com/1/followers/ids.json',
        'cursor' => cursor,
        'screen_name' => SCREEN_NAME)
      json = JSON.parse(res.body)
      result << json
      # get_followers(json['next_cursor_str'])
      return result.flatten!
    end
  end

  # Get followings
  def get_followings(cursor = '-1')
    puts "get_followings: cursor=#{cursor}"
    result = []
    if (cursor != '0')
      res = @access_token.get('https://api.twitter.com/1/friends/ids.json',
        'cursor' => cursor,
        'screen_name' => SCREEN_NAME)
      json = JSON.parse(res.body)
      result << json
      # get_followings(json['next_cursor_str'])
      return result.flatten!
    end
  end

  # Follow the user that he/she follows me but I don't.
  # [RETURN] Number of following users after this following process.
  def follow_unfollowing_user
    # Following new users
    # followers - following = need to follow
    followers = get_followers
    followings = get_followings
    need_to_follow = followers - followings

    puts "need to follow: "
    for id in need_to_follow do
      puts " #{id}"
    end

    for id in need_to_follow do
      follow_user id
    end

    return followings.size + need_to_follow.size
  end

  # Remove the user that he/she removed me but I'm still following.
  # [RETURN] Number of following users after this removing process.
  def remove_removed_user
    followers = get_followers
    followings = get_followings
    need_to_remove = followings - followers

    puts 'need to remove: '
    for id in need_to_remove do
      puts " #{id}"
    end

    for id in need_to_remove do
      remove_user id
    end
    
    return followings.size - need_to_remove.size
  end

  # Reading the text for tweet from files.
  def read_post_text_files
    open(MENTION_FILE, 'r:UTF-8') do |file|
      @reply_mention_text = file.readlines.collect{|line| line.strip}
    end

    open(NOTMEITAN_FILE, 'r:UTF-8') do |file|
      @notmeitan_text = file.readlines.collect{|line| line.strip}
    end

    open(REPLY_CSHARP_FILE, 'r:UTF-8') do |file|
      @reply_csharp_text = file.readlines.collect{|line| line.strip}
    end
    
    open(REPLY_MORNING_FILE, 'r:UTF-8') do |file|
      @reply_morning_text = file.readlines.collect{|line| line.strip}
    end

    puts 'notmeitan text:'
    for s in @notmeitan_text do
      puts ' ' + s
    end

    puts 'reply text:'
    for s in @reply_mention_text do
      puts ' ' + s
    end

    puts 'reply csharp text:'
    for s in @reply_csharp_text do
      puts ' ' + s
    end
  end
  
  # Control this bot.
  # _command_ is command symbol.
  # _params_ is command parameters. Parameters is array.
  # If _report_by_message is true, report the command result by sending direct message to owner. By default, this is true.
  def control_command(command, params, report_by_message = true)
    case command
    when :is_ignore_owner
      if params[0]
        case params[0].to_sym
        when :true
          @is_ignore_owner = true
        when :false
          @is_ignore_owner = false
        else
          puts 'unknown value'
        end
      else
        puts 'no param'
      end
      puts "command<is_ignore_owner> accepted. current value is #{@is_ignore_owner}"
      send_direct_message("command<is_ignore_owner> accepted. current value is #{@is_ignore_owner}", OWNER_ID) if report_by_message
    when :is_ignore_owner?
      puts "inquiry<is_ignore_owner> accepted. current value is #{@is_ignore_owner}"
      send_direct_message("inquiry<is_ignore_owner> accepted. current value is #{@is_ignore_owner}", OWNER_ID) if report_by_message
    when :is_enable_posting
      if params[0]
        case params[0].to_sym
        when :true
          @is_enabled_posting = true
        when :false
          @is_enabled_posting = false
        else
          puts 'unknown value'
        end
      else
        puts 'no param'
      end
      puts "command<is_enable_posting> accepted. current value is #{@is_enabled_posting}"
      send_direct_message("command<is_enable_posting> accepted. current value is #{@is_enabled_posting}", OWNER_ID) if report_by_message
    when :is_enable_posting?
      puts "inquiry<is_enable_posting> accepted. current value is #{@is_enabled_posting}"
      send_direct_message("inquiry<is_enable_posting> accepted. current value is #{@is_enabled_posting}", OWNER_ID) if report_by_message
    when :show_post_text_count
      puts "command<show_post_text_count> accepted. meitan:#{@notmeitan_text.size}, reply:#{@reply_mention_text.size}, csharp:#{@reply_csharp_text.size}"
      send_direct_message("command<show_post_text_count> accepted. meitan:#{@notmeitan_text.size}, reply:#{@reply_mention_text.size}, csharp:#{@reply_csharp_text.size}", OWNER_ID) if report_by_message
    when :reload_post_text
      read_post_text_files
      puts "command<reload_post_text> accepted. meitan:#{@notmeitan_text.size}, reply:#{@reply_mention_text.size}, csharp:#{@reply_csharp_text.size}"
      send_direct_message("command<reload_post_text> accepted. meitan:#{@notmeitan_text.size}, reply:#{@reply_mention_text.size}, csharp:#{@reply_csharp_text.size}", OWNER_ID) if report_by_message
    when :ignore_user
      log = "command<ignore_user> accepted."
      id = 0
      begin
        id = Integer(params[1])
      rescue
        puts 'ID Conversion failure.'
      end
      unless id == 0
        if params[0]
          case params[0].to_sym
          when :add
            unless IGNORE_IDS.include?(id)
              IGNORE_IDS.concat id
              log += " added #{id}"
            end
          when :remove
            if IGNORE_IDS.include?(id)
              IGNORE_IDS.delete id
              log += " removed #{id}"
            end
          end
        else
          puts 'no param'
        end
      else
        puts 'ID is 0'
      end
      log += " current ignoring users: #{IGNORE_IDS.size}"
      puts log
      send_direct_message(log, OWNER_ID) if report_by_message
    when :check_friendships
      follow_unfollowing_user
      users = remove_removed_user
      puts "command<check_friendships> accepted. current followings: #{users}"
    when :show_friendships
      followings = get_followings
      followers = get_followers
      puts "inquiry<show_friendships> accepted. followings/followers=#{followings.size}/#{followers.size}"
    when :help
      puts "inquiry<help> accepted. Available commands: is_ignore_owner(?), is_enable_posting(?), reload_post_text, ignore_user."
      send_direct_message("This function is only available on command-line.") if report_by_message
    else
      puts 'unknown command received. to show help, please send help command.'
      send_direct_message('unknown command received.') if report_by_message
    end
  end

end


if $0 == __FILE__
  bot = MeitanBot.new
  bot.run

  command_line_vars = {is_report_enabled: false}

  loop do
    print 'meitan-bot> '  
    line = gets
    line.chop!
    cmd_ary = line.split(nil, 2)
    redo unless cmd_ary[0]
    case cmd_ary[0].to_sym
    when :show_vars
      puts command_line_vars.inspect
    when :is_report_enabled
      if cmd_ary[1]
        case cmd_ary[1].to_sym
        when :true
          is_report_enabled = true
        when :false
          is_report_enabled = false
        end
      end
      puts "Report by Direct Message: #{command_line_vars[:is_report_enabled]}"
    when :exit, :quit
      break
    else
      param = cmd_ary[1] ? cmd_ary[1].split : []
      bot.control_command(cmd_ary[0].to_sym, param, command_line_vars[:is_report_enabled])
    end
  end
end
