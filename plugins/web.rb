#
# Web services plugin. Google and more.
#

require 'net/http'
require 'uri'
require 'htmlentities'

class Web < PluginBase

  def initialize
    @brief_help = 'Performs various web services.'
    @requests = 0
    @max_requests = 4
    super
  end

  def cmd_title(irc, line)
    if !line or line.empty?
      irc.reply 'USAGE: title <http-url>'
    elsif @requests >= @max_requests
      irc.reply 'My limit of outstanding web queries has been reached. Try again in a moment.'
    else
      line = "http://#{line}" unless line =~ /^http:\/\//
      if !(uri = URI.parse(line)) or !uri.kind_of?(URI::HTTP)
        irc.reply 'Error parsing URL.  For now, only HTTP URLs are accepted.'
      else
        Thread.new do
          begin
            @requests += 1
            Net::HTTP.start(uri.host, uri.port) do |http|
              buffer = ''
              path = uri.path
              res = http.get(path.empty? ? '/' : path) do |s|
                buffer << s
                if buffer =~ /<title>(.+?)<\/title>/
                  irc.reply $1.decode_entities
                  Thread.exit
                end
              end
              irc.reply 'No title found in document.'
            end
          rescue SocketError
            irc.reply 'Error connecting to host.'
          ensure
            @requests -= 1
          end
        end
      end
    end
  end

  def cmd_google(irc, line)

    # Argument checks.
    if !line or line.empty?
      irc.reply 'USAGE: google <search string>'
      return
    end
    if @requests >= @max_requests
      irc.reply 'My limit of outstanding web queries has been reached. Try again in a moment.'
      return
    end

    # Let's google!
    Thread.new do
      begin
        @requests += 1
        Net::HTTP.start('www.google.com') do |http|
          search = line.gsub(/[^a-zA-Z0-9_\.\-]/) { |s| sprintf('%%%02x', s[0]) }
          re = http.get("/search?ie=utf8&oe=utf8&q=#{search}", 
            { 'User-Agent' => 'CyBrowser' })
          if re.code == '200'
            if re.body =~ /<a href="([^"]+)" class=l>(.+?)<\/a>/
              link = $1.decode_entities
              desc = $2.gsub('<b>', "\x02").gsub('</b>', "\x0f").decode_entities
              irc.reply "#{link} (#{desc})"
            elsif re.body =~ /did not match any documents/
              irc.reply 'Nothing found.'
            else
              irc.reply "Error parsing Google output."
            end
          else
            irc.reply "Google returned an error: #{re.code} #{re.message}"
          end
        end
      ensure
        @requests -= 1
      end
    end

  end
  help :google, 'Searches the web with Google, returning the first result.'
  alias_method :cmd_lucky, :cmd_google
  help :lucky, "Alias for 'google'. Type 'google?' for more information."

end

