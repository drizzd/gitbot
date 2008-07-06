#!/usr/bin/env ruby -wKU

require "net/http"
require 'rss'
require "uri"
require 'cgi'
require "yaml"

class Exception
  def self.pretty(e)
    str = "#{e.class.name}: #{e.message.sub(/`(\w+)'/, '‘\1’').sub(/ -- /, ' — ')}\n\n"

    e.backtrace.each do |b|
      if b =~ /(.*?):(\d+)(?::in\s*`(.*?)')?/ then
        file, line, method = $1, $2, $3
        display_name = File.basename(file)
        str << "At line #{line} in ‘#{display_name}’ "
        str << (method ? "(inside method ‘#{method}’)" : "(top level)")
        str << "\n"
      end
    end

    str
  end
end

module FeedStuff
  class Resource
    attr_reader :uri_string
    def initialize(uri_string, etag = nil)
      @uri_string = uri_string
      @etag       = etag
    end

    def request(uri_string, etag = nil)
      uri  = URI.parse(uri_string)
      path = uri.path.empty? ? '/' : uri.path
      re   = Net::HTTP.start(uri.host, uri.port) { |http| http.get(path, etag.nil? ? nil : { 'If-None-Match' => etag }) }

      if re.kind_of? Net::HTTPSuccess
        @etag = re['ETag']
        $log.puts "#{uri.host}: New items"
        re
      elsif re.kind_of? Net::HTTPFound
        $log.puts "#{uri.host}: Found (redirect) → " + re['Location']
        request(re['Location'], etag)
      elsif re.kind_of? Net::HTTPMovedPermanently
        $log.puts "#{uri.host}: Permanent redirect → " + re['Location']
        request(re['Location'], etag)
      elsif re.kind_of? Net::HTTPTemporaryRedirect
        $log.puts "#{uri.host}: Temporary redirect → " + re['Location']
        request(re['Location'], etag)
      elsif re.kind_of? Net::HTTPNotModified
        $log.puts "#{uri.host}: Not modified."
        nil
      elsif re.kind_of? Net::HTTPNotFound
        $log.puts "#{uri.host}: WARNING: Not Found."
        nil
      else
        raise "Unknown response (#{re.code}) from #{uri_string}"
      end
    end

    def get
      begin
        if re = request(@uri_string, @etag)
          return re.body 
        end
      rescue Exception => e
        $log.puts "*** network error"
        $log.puts Exception.pretty(e)
      end
      nil
    end

    def save
      res = { 'uri' => @uri_string }
      res['etag'] = @etag unless @etag.nil?
      res
    end
  end

  class Feed
    class Item
      def initialize(channel, item, master)
        @channel = channel
        @item    = item
        @master  = master
      end

      def read=(flag)
        @master.did_read(self) if flag
      end

      def guid
        if @item.respond_to? :guid
          @item.guid.content 
        else
          @item.link
        end
      end

      def title
        @item.title
      end

      def summary(limit = 420)
        prefix = "[#{@channel.title}] #{@item.title}: "
        suffix = @item.link ? " — #{@item.link}" : ''
        length = limit - prefix.length - suffix.length

        body   = @item.description.gsub(/<.*?>/, ' ')
        body   = CGI::unescapeHTML(body)
        body   = body.gsub(/\s+/, ' ').gsub(/\A\s+|\s+\z/, '')
        body   = body.sub(/(.{0,#{length}})(\s.+)?$/) { $1 + ($2.nil? ? '' : '…')}

        prefix + body + suffix
      end

      attr_reader :item
      def <=>(other)
        # as of Ruby 1.8.6 the RSS library only reads pubDate, not dc::date
        if @item.date and other.item.date
          @item.date <=> other.item.date
        else
          @item.date ? 1 : (other.item.date ? -1 : 0)
        end
      end
    end

    def initialize(uri_string, etag = nil, last_check = nil, seen = [])
      @ressource  = Resource.new(uri_string, etag)
      @last_check = last_check
      @seen       = seen
      @unread     = []
    end

    def unread
      if body = @ressource.get
        if rss = RSS::Parser.parse(body, false)
          new_items = rss.items.map { |e| Item.new(rss.channel, e, self) }
          new_items.reject! { |item| @seen.include? item.guid }
          $log.puts "Got " + new_items.size.to_s + " new items"
          @seen.concat(new_items.map { |item| item.guid })
          @unread.concat(new_items)
        else
          $log.puts "Error parsing feed at " + @ressource.save['uri']
        end
      end
      @last_check = Time.now
      @unread.sort!
      @unread = @unread[-5..-1] if @unread.size > 5
      @unread.dup
    end

    def did_read(item)
      @unread.reject! { |e| e.guid == item.guid }
    end

    def save
      res = { 'seen' => @seen }
      res['last_check'] = @last_check unless @last_check.nil?
      res.merge(@ressource.save)
    end

    def to_s
      @ressource.uri_string
    end
  end

  feeds = []

  module_function

  def load(filename)
    uris = %w{
      http://henrik.nyh.se/feed/
      http://macromates.com/blog/feed/
      http://macromates.com/blog/comments/feed/
      http://macromates.com/svnlog/bundles.rss
      http://macromates.com/textmate/screencast.rss
      http://macromates.com/textmate/changelog.rss
      http://blog.grayproductions.net/index.rss
      http://theocacao.com/index.rss
      http://blog.circlesixdesign.com/feed/
      http://kevin.sb.org/feed/
      http://ciaranwal.sh/feed
      http://subtlegradient.com/xml/rss/feed.xml
    }

    defaults = uris.map { |uri| Feed.new(uri) }
    @feeds = open(filename) { |io| YAML.load(io).map { |e| Feed.new(e['uri'], e['etag'], e['last_check'], e['seen']) } } rescue defaults
  end
  
  def save(filename)
    open(filename, 'w') do |io|
      io << "# Feeds we follow and their status.\n"
      io << "# Last update: #{Time.now.strftime('%F %T')}.\n"
      YAML.dump(@feeds.map { |e| e.save }, io)
      io << "\n"
    end
  end

  def run(out = STDOUT, filename = '/tmp/feeds.yaml', period = 30*60)
    tr = Thread.new do
      begin
        load(filename)

        while true
          $log.puts Time.now.strftime('%H:%M:%S: Checking feeds…')

          @feeds.each do |feed|
            begin
              feed.unread.each do |item|
                out.puts item.summary
                sleep(2)
                item.read = true
              end
            rescue Exception => e
              $log.puts "*** exception while iterating feeds (#{feed})"
              $log.puts Exception.pretty(e)
            end
          end

          save(filename)

          $log.puts Time.now.strftime('%H:%M:%S: Done checking feeds!')
          sleep(period)
        end
      rescue Exception => e
        $log.puts "*** thread error"
        $log.puts Exception.pretty(e)
      end
    end
  end

  def add(uri)
    @feeds << Feed.new(uri)
  end
end

if $0 == __FILE__

  $log = STDERR
  tr = FeedStuff.run
  tr.join

else

# ===================
# = Cybot Interface =
# ===================

class Feed < PluginBase
  def initialize(*args)
    @brief_help = 'Feeds the channel with hot news from various RSS channels'
    @filename   = nil
    @did_start  = false

    $config.merge(
      'plugins' => {
        :dir => true,
        'feed' => {
          :help => 'Settings for the feed plugin.',
          :dir => true,
          'server' => 'The server to output feed items to.',
          'channel' => 'The channel to output feed items to.'
        }
      }
    )
    super(*args)
  end

  # Checks whether the user is allowed to use this plugin
  # Informs them and returns false if not 
  def authed?(irc)
    if !$user.caps(irc, 'phrases', 'op', 'owner').any?
      irc.reply "You aren't allowed to use this command"
      return false
    end
    true
  end

  # We can’t start the thread before we have the irc object
  # this method seems to be the quickest way to grab it
  def hook_init_chan(irc)
    return if @did_start
    if irc.server.name == $config['plugins/feed/server'] && irc.channel.nname == $config['plugins/feed/channel']
      FeedStuff.run(irc, @filename)
      @did_start = true
    end
  end

  def cmd_subscribe(irc, line)
    return unless authed?(irc)
    irc.reply("Not yet implemented.")
    # FeedStuff.add(line)
  end
  help :subscribe, "Subscribe to an RSS feed."

  # We want to load in the thread, so we only store the filename
  def load
    @filename = File.expand_path(file_name('feeds.yml'))
  end
end

end
