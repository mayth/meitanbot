#! ruby -Ku

require 'net/https'
require 'oauth'
require 'json'
require 'kconv'
require 'yaml'
require 'twitter'

class MeitanBot
  # files
  CREDENTIAL_FILE = 'credential.yaml'
  NOTMEITAN_FILE = 'notmeitan.txt'
  MENTION_FILE = 'reply_mention.txt'
  REPLY_CSHARP_FILE = 'reply_csharp.txt'
  HTTPS_CA_FILE = 'certificate.crt'
  
  # bot constants
  SCREEN_NAME = 'meitanbot'
  BOT_USER_AGENT = 'Nowhere-type Meitan bot 1.0 by @maytheplic'
  MAX_RETRY_COUNT = 5
  OWNER_ID = 246793872
  MY_ID = 323080975
  IGNORE_IDS = [MY_ID]

  def initialize
    # fields
    @is_ignore_owner = true
    @is_output_json_in_log = false
    
    # credentials
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
  
  def run
  	first_run = true
    retry_count = 0
    loop do
      begin
        connect do |json|
	  	  if (first_run)
			follow_unfollowing_user
	        tweet_greeting
		    first_run = false
		  end
		  t = Time.now.getutc
		  if t.sec == 0 and t.min == 0
		    tweet_timer_greeting t.hour + 7
		  end
          if json['text']
            puts "Post Received."
			user = json['user']
			unless IGNORE_IDS.include?(user['id']) or (@is_ignore_owner and user['id'] == OWNER_ID)
              if /.*め[　 ーえぇ]*い[　 ーいぃ]*た[　 ーあぁ]*ん.*/ =~ json['text']
                puts "meitan detected. reply to #{json['id']}"
			    reply_meitan(user['screen_name'], json['id'])
              elsif /^@#{SCREEN_NAME}/ =~ json['text']
			    puts "reply detected. reply to #{json['id']}"
                reply_mention(user['screen_name'], json['id'])
              elsif /.*C#.*/ =~ json['text']
                puts "C# detected. reply to #{json['id']}"
                reply_csharp(user['screen_name'], json['id'])
              end
			else
			  puts "ignore list includes id:#{user['id']}. ignored."
			end
          elsif json['event']
            puts 'Event Received.'
	        case json['event'].to_sym
			  when :follow
			    puts "new follower: #{json['source']}"
		        follow_user json['source']['id'] 
            end
          elsif json['direct_message']
            puts 'Direct Message Received.'
            sender = json['direct_message']['sender']
            text = json['direct_message']['text'].strip
            if sender['id'] == OWNER_ID && text.start_with?('cmd')
              puts "Received Command Message"
              cmd_ary = text.split
              case cmd_ary[1].to_sym
                when :is_ignore_owner
                  case cmd_ary[2].to_sym
                    when :true
                      @is_ignore_owner = true
                    when :false
                      @is_ignore_owner = false
                  end
                puts "command<is_ignore_owner> accepted. current value is #{@is_ignore_owner}"
                send_direct_message(
                  "command<is_ignore_owner> accepted. current value is #{@is_ignore_owner}",
                  OWNER_ID)
              end
            end
		  end
        end
	  rescue Timeout::Error, StandardError
        if (retry_count < 5)
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
  
  def tweet_greeting
    puts "greeting"
	post 'starting meitan-bot. Hello! ' + Time.now.strftime("%X")
  end

  def tweet_timer_greeting(hour)
    puts "timer greeting"
	post "#{hour}時(TST)をお知らせします。"
  end

  def reply_meitan(reply_screen_name, in_reply_to_id)
    puts "replying to meitan"
    post_reply("@#{reply_screen_name} #{random_notmeitan}", in_reply_to_id)
  end
  
  def reply_mention(reply_screen_name, in_reply_to_id)
    puts "replying to mention"
    post_reply("@#{reply_screen_name} #{random_mention}", in_reply_to_id)
  end

  def reply_csharp(reply_screen_name, in_reply_to_id)
    puts "replying to csharp"
    post_reply("@#{reply_screen_name} #{random_csharp}", in_reply_to_id)
  end

  def post_reply(status, in_reply_to_id)
  	puts "replying"
	@access_token.post('https://api.twitter.com/1/statuses/update.json',
		'status' => status,
		'in_reply_to_status_id' => in_reply_to_id)
  end

  def post(status)
  	puts "posting"
	@access_token.post('https://api.twitter.com/1/statuses/update.json',
		'status' => status)
  end
  
  def send_direct_message(text, recipient_id)
    puts "Sending Direct Message"
    @access_token.post('https://api.twitter.com/1/direct_messages/new.json',
      'user_id' => recipient_id,
      'text' => text)
  end
  
  def follow_user(id)
    unless id == MY_ID
      puts "following user: #{id}"
      @access_token.post('https://api.twitter.com/1/friendships/create.json',
        'user_id' => id)
    end
  end

  def random_notmeitan
    @notmeitan_text.sample
  end
  
  def random_mention
    @reply_mention_text.sample
  end
  
  def random_csharp
    @reply_csharp_text.sample
  end
  
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

  def follow_unfollowing_user
    # Following new users
    # followers - following = need to follow
    followers = get_followers
    followings = get_followings
    need_to_follow = followers - followings

    puts "followers: "
    for id in followers do
      puts " #{id}"
    end
    puts "followings: "
    for id in followings do
      puts " #{id}"
    end
    puts "need to follow: "
    for id in need_to_follow do
      puts " #{id}"
    end

    for id in need_to_follow do
      follow_user id
    end
  end
  
  def read_post_text_files
    open(MENTION_FILE) do |file|
      @reply_mention_text = file.readlines.collect{|line| line.strip}
    end

    open(NOTMEITAN_FILE) do |file|
      @notmeitan_text = file.readlines.collect{|line| line.strip}
    end
    
    open(REPLY_CSHARP_FILE) do |file|
      @reply_csharp_text = file.readlines.collect{|line| line.strip}
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
end

class Timer
  def initialize(sec)
    @th = Thread.new do
	  while true do
	    sleep sec;
	    yield
	  end
	end
  end

  def stop
    @th.stop
  end
end

if $0 == __FILE__
  botThread = Thread.new do
    MeitanBot.new.run
  end
  botThread.join
end
