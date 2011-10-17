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
  SCREEN_NAME = 'meitanbot'
  BOT_USER_AGENT = 'Nowhere-type Meitan bot 1.0 by @maytheplic'
  HTTPS_CA_FILE = 'certificate.crt'
  MAX_RETRY_COUNT = 5
  
  def initialize
    # credentials
    open(CREDENTIAL_FILE) do |file|
	  @credential = YAML.load(file)
    end

    puts "credential:"
    puts " consumer_key = #{@credential['consumer_key']}"
    puts " consumer_secret = #{@credential['consumer_secret']}"
    puts " access_token = #{@credential['access_token']}"
    puts " access_token_secret = #{@credential['access_token_secret']}"
    
    @consumer = OAuth::Consumer.new(
      @credential['consumer_key'],
      @credential['consumer_secret']
    )
    @access_token = OAuth::AccessToken.new(
      @consumer,
      @credential['access_token'],
      @credential['access_token_secret']
    )
     
    open(MENTION_FILE) do |file|
      @reply_mention_text = file.readlines.collect{|line| line.strip}
    end

    open(NOTMEITAN_FILE) do |file|
      @notmeitan_text = file.readlines.collect{|line| line.strip}
    end
    
    for s in @notmeitan_text do
      puts s
    end
    
    for s in @reply_mention_text do
      puts s
    end
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
          if json['text']
            puts "Post Received."
			user = json['user']
			unless user['id'] == 323080975 or user['id'] == 246793872
              if /.*め[　 ーえぇ]*い[　 ーいぃ]*た[　 ーあぁ]*ん.*/ =~ json['text']
                puts "meitan detected. reply to #{json['id']}"
			    reply_meitan(user['screen_name'], json['id'])
              elsif /.*@#{SCREEN_NAME}.*/ =~ json['text']
			    puts "mention detected. reply to #{json['id']}"
                reply_mention(user['screen_name'], json['id'])
              end
			else
			  puts "post from own or owner. ignored."
			end
          elsif json['event']
	        case json['event'].to_sym
			  when :follow
			    puts "new follower: #{json['source']}"
		        follow_user json['source']['id'] 
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

  def reply_meitan(reply_screen_name, in_reply_to_id)
    puts "replying to meitan"
    post_reply("@#{reply_screen_name} #{random_notmeitan}", in_reply_to_id)
  end
  
  def reply_mention(reply_screen_name, in_reply_to_id)
    puts "replying to mention"
    post_reply("@#{reply_screen_name} #{random_mention}", in_reply_to_id)
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
  
  def follow_user(id)
    puts "following user: #{id}"
    @access_token.post('https://api.twitter.com/1/friendships/create.json',
      'user_id' => id)
  end

  def random_notmeitan
    @notmeitan_text[rand(@notmeitan_text.size)]
  end
  
  def random_mention
    @reply_mention_text[rand(@reply_mention_text.size)]
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
end

if $0 == __FILE__
  MeitanBot.new.run
end
