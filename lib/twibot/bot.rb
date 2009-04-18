require 'logger'
require File.join(File.expand_path(File.dirname(__FILE__)), 'macros')
require File.join(File.expand_path(File.dirname(__FILE__)), 'handlers')

module Twibot
  #
  # Main bot "controller" class
  #
  class Bot
    include Twibot::Handlers
    attr_reader :twitter
    attr_writer :prompt

    def initialize(options = nil, prompt = false)
      @prompt = prompt
      @conf = nil
      @config = options || Twibot::Config.default << Twibot::FileConfig.new << Twibot::CliConfig.new
      @log = nil
      @abort = false
    rescue Exception => krash
      raise SystemExit.new(krash.message)
    end

    def prompt?
      @prompt
    end

    def processed
      @processed ||= {
        :message => nil,
        :reply => nil,
        :tweet => nil
      }
    end

    def twitter
      @twitter ||= Twitter::Client.new :login => config[:login], :password => config[:password]
    end

    #
    # Run application
    #
    def run!
      puts "Twibot #{Twibot::VERSION} imposing as @#{login}"

      trap(:INT) do
        puts "\nAnd it's a wrap. See ya soon!"
        exit
      end
      
      choose_tweets_to_process

      poll
    end


    #
    # Configure bot
    #
    def configure
      yield @config
      @conf = nil
      @twitter = nil
    end

   private
   
    #
    # Return logger instance
    #
    def log
      return @log if @log
      os = config[:log_file] ? File.open(config[:log_file], "a") : $stdout
      @log = Logger.new(os)
      @log.level = Logger.const_get(config[:log_level] ? config[:log_level].upcase : "INFO")
      @log
    end   
   
    #
    # Poll Twitter API in a loop and pass on messages and tweets when they appear
    #
    def poll
      max = max_interval
      step = interval_step
      interval = min_interval

      while !@abort do
        message_count = 0
        message_count += receive_messages || 0
        message_count += receive_replies || 0
        message_count += receive_tweets || 0

        interval = message_count > 0 ? min_interval : [interval + step, max].min

        log.debug "Sleeping for #{interval}s"
        sleep interval
      end
    end

    #
    # Receive direct messages
    #
    def receive_messages
      type = :message
      return false unless handlers[type].length > 0
      options = {}
      options[:since_id] = processed[type] if processed[type]
      begin
        dispatch_messages(type, twitter.messages(:received, options), %w{message messages})
      rescue Twitter::RESTError => e
        log.error("Failed to connect to Twitter.  It's likely down for a bit:")
        log.error(e.to_s)
        0
      end
    end

    #
    # Receive tweets
    #
    def receive_tweets
      type = :tweet
      return false unless handlers[type].length > 0
      options = {}
      options[:since_id] = processed[type] if processed[type]
      begin
        dispatch_messages(type, twitter.timeline_for(config.to_hash[:timeline_for] || :public, options), %w{tweet tweets})
      rescue Twitter::RESTError => e
        log.error("Failed to connect to Twitter.  It's likely down for a bit:")
        log.error(e.to_s)
        0
      end
    end

    #
    # Receive tweets that start with @<login>
    #
    def receive_replies
      type = :reply
      return false unless handlers[type].length > 0
      options = {}
      options[:since_id] = processed[type] if processed[type]
      begin
        dispatch_messages(type, twitter.status(:replies, options), %w{reply replies})
      rescue Twitter::RESTError => e
        log.error("Failed to connect to Twitter.  It's likely down for a bit:")
        log.error(e.to_s)
        0
      end

    end

    #
    # Dispatch a collection of messages
    #
    def dispatch_messages(type, messages, labels)
      messages.each { |message| dispatch(type, message) }
      # Avoid picking up messages over again
      processed[type] = messages.first.id if messages.length > 0

      num = messages.length
      log.info "Received #{num} #{num == 1 ? labels[0] : labels[1]}"
      num
    end
   
    #
    # Map configuration settings
    #
    def method_missing(name, *args, &block)
      return super unless config.key?(name)

      self.class.send(:define_method, name) { config[name] }
      config[name]
    end

    #
    # Return configuration
    #
    def config
      return @conf if @conf
      @conf = @config.to_hash

      if prompt? && (!@conf[:login] || !@conf[:password])
        # No need to rescue LoadError - if the gem is missing then config will
        # be incomplete, something which will be detected elsewhere
        begin
          require 'highline'
          hl = HighLine.new

          @config.login = hl.ask("Twitter login: ") unless @conf[:login]
          @config.password = hl.ask("Twitter password: ") { |q| q.echo = '*' } unless @conf[:password]
          @conf = @config.to_hash
        rescue LoadError
          raise SystemExit.new( <<-HELP
Unable to continue without login and password. Do one of the following:
  1) Install the HighLine gem (gem install highline) to be prompted for credentials
  2) Create a config/bot.yml with login: and password:
  3) Put a configure { |conf| conf.login = "..." } block in your bot application
  4) Run bot with --login and --password options
          HELP
          )
        end
      end

      @conf
    end
    
    # 
    # Decides which tweets the bot should ignore and which it should 
    # process based on the :process configuration option
    # 
    def choose_tweets_to_process
      case config[:process]
      when :all, nil
        # do nothing so it will fetch ALL
      when :new
        # Make sure we don't process messages and tweets received prior to bot launch
        messages = twitter.messages(:received, { :count => 1 })
        processed[:message] = messages.first.id if messages.length > 0

        handle_tweets = !handlers.nil? && handlers[:tweet].length + handlers[:reply].length > 0
        tweets = []

        begin
          tweets = handle_tweets ? twitter.timeline_for(config[:timeline_for], { :count => 1 }) : []
        rescue Twitter::RESTError => e
          log.error("Failed to connect to Twitter.  It's likely down for a bit:")
          log.error(e.to_s)
        end

        processed[:tweet] = tweets.first.id if tweets.length > 0
        processed[:reply] = tweets.first.id if tweets.length > 0
      when Numeric, /\d+/ # a tweet ID to start from
        processed[:tweet] = processed[:reply] = processed[:message] = config[:process]
      else abort "Unknown process option #{config[:process]}, aborting..."
      end
    end
    
  end
end

# Expose DSL
include Twibot::Macros

# Run bot if macros has been used
at_exit do
  raise $! if $!
  @@bot.run! if run?
end
