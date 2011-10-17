#! ruby -Ku

require 'rubygems'
require 'net/https'
require 'oauth'
require 'json'
require 'kconv'

def puts_sjis(s)
  puts Kconv.tosjis(s.to_s)
end

class MeitanBot
  # files
  TOKENS_FILE = 'tokens'
  NOTMEITAN_FILE = 'notmeitan.txt'
  MENTION_FILE = 'reply_mention.txt'
  SCREEN_NAME = 'meitanbot'
  BOT_USER_AGENT = 'Nowhere-type Meitan bot 1.0 by @maytheplic'
  HTTPS_CA_FILE = 'certificate.crt'
  MAX_RETRY_COUNT = 5
  
  def initialize
    # key / tokens
    consumer_key = ""
    consumer_secret = ""
    access_token = ""
    access_token_secret = ""

    open(TOKENS_FILE) do |file|
      consumer_key = file.gets
      consumer_secret = file.gets
      access_token = file.gets
      access_token_secret = file.gets
    end
    
    puts "consumer_key = #{consumer_key}"
    puts "consumer_secret = #{consumer_secret}"
    puts "access_token = #{access_token}"
    puts "access_token_secret = #{access_token_secret}"
    
    @consumer = OAuth::Consumer.new(
      consumer_key,
      consumer_secret,
      :site => 'http://twitter.com'
    )
    @access_token = OAuth::AccessToken.new(
      @consumer,
      access_token,
      access_token_secret
    )
    
    open(NOTMEITAN_FILE) do |file|
      @reply_mention_text = file.readlines.collect{|line| line.strip}
    end

    open(MENTION_FILE) do |file|
      @notmeitan_text = file.readlines.collect{|line| line.strip}
    end
    
    for s in @notmeitan_text do
      puts_sjis s
    end
    
    for s in @reply_mention_text do
      puts_sjis s
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
      
      # Following new users
      # followers - following = need to follow
      followers = get_followers
      followings = get_followings
      need_to_follow = followers - following

      puts "followers: "
      for id in followers do
        puts_sjis " #{id}"
      end
      puts "followings: "
      for id in followings do
        puts_sjis " #{id}"
      end
      puts "need to follow: "
      for id in need_to_follow do
        puts_sjis " #{id}"
      end

      for id in need_to_follow do
        follow_user id
      end
      
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
    retry_count = 0
    loop do
      begin
        connect do |json|
          puts_sjis json.to_s
          if json['text']
            puts "Event Received."
            user = json['user']
            if (json['text'].match("/.*め[　 ーえぇ]*い[　 ーいぃ]*た[　 ーあぁ]ん.*/"))
              reply_meitan json['id']
            end
            if (json['text'].match("/.*@#{SCREEN_NAME}.*/"))
              reply_mention json['id']
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
  
  def reply_meitan(in_reply_to_id)
    puts "replying to meitan"
    @access_token.post('/statuses/update.json',
      'status' => "@#{user['screen_name']} #{random_notmeitan}",
      'in_reply_to_status_id' => in_reply_to_id)
  end
  
  def reply_mention(in_reply_to_id)
    puts "replying to mention"
    @access_token.post('/statuses/update.json',
      'status' => "@#{user['screen_name']} #{random_notmeitan}",
      'in_reply_to_status_id' => in_reply_to_id)
  end
  
  def follow_user(id)
    puts "following user: #{id}"
    @access_token.post('/friendships/create.json',
      'user_id' => id)
  end

  def random_notmeitan
    @notmeitan_text[rand(@notmeitan_text.size)]
  end
  
  def random_mention
    @reply_mention_text[rand(@reply_mention_text.size)]
  end
  
  def get_followers(cursor=-1)
    result = []
    if (cursor != 0)
      json = JSON.parse(@access_token.get('/followers/ids.json',
        'cursor' => cursor,
        'screen_name' => SCREEN_NAME))
      result << json['ids']
      get_followers(json['next_cursor'])
      return result.flatten!
    end
  end
  
  def get_followings(cursor=-1)
    result = []
    if (cursor != 0)
      json = JSON.parse(@access_token.get('/friends/ids.json',
        'cursor' => cursor,
        'screen_name' => SCREEN_NAME))
      result << json['ids']
      get_followings(json['next_cursor'])
      return result.flatten!
    end
  end
end

if $0 == __FILE__
  MeitanBot.new.run
end