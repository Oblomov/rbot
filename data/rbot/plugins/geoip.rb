#-- vim:sw=2:et
#++
#
# :title: Geo IP Plugin
#
# Author:: Raine Virta <rane@kapsi.fi>
# Copyright:: (C) 2008 Raine Virta
# License:: GPL v2
#
# Resolves the geographic locations of users (network-wide) and IP addresses

module ::GeoIP
  class InvalidHostError < RuntimeError; end
  class BadAPIError < RuntimeError; end

  HOST_NAME_REGEX  = /^[a-z0-9\-]+(?:\.[a-z0-9\-]+)*\.[a-z]{2,4}/i

  def self.valid_host?(hostname)
    hostname =~ HOST_NAME_REGEX ||
    hostname =~ Resolv::IPv4::Regex && (hostname.split(".").map { |e| e.to_i }.max <= 255)
  end

  def self.geoiptool(bot, ip)
    url = "http://www.geoiptool.com/en/?IP="
    regexes  = {
      :country => %r{Country:.*?<a href=".*?" target="_blank"> (.*?)</a>}m,
      :region  => %r{Region:.*?<a href=".*?" target="_blank">(.*?)</a>}m,
      :city    => %r{City:.*?<td align="left" class="arial_bold">(.*?)</td>}m,
      :lat     => %r{Latitude:.*?<td align="left" class="arial_bold">(.*?)</td>}m,
      :lon     => %r{Longitude:.*?<td align="left" class="arial_bold">(.*?)</td>}m
    }
    res = {}
    raw = bot.httputil.get_response(url+ip)
    raw = raw.decompress_body(raw.raw_body)

    regexes.each { |key, regex| res[key] = raw.scan(regex).join('') }

    return res
  end

  IPINFODB_URL = "http://api.ipinfodb.com/v2/ip_query.php?key=%{key}&ip=%{ip}"

  def self.ipinfodb(bot, ip)
    key = bot.config['geoip.ipinfodb_key']
    return if not key or key.empty?
    url = IPINFODB_URL % {
      :ip => ip,
      :key => key
    }
    debug "Requesting #{url}"

    xml = bot.httputil.get(url)

    if xml
      obj = REXML::Document.new(xml)
      debug "Found #{obj}"
      newobj = {
        :country => obj.elements["Response"].elements["CountryName"].text,
        :city => obj.elements["Response"].elements["City"].text,
        :region => obj.elements["Response"].elements["RegionName"].text,
      }
      debug "Returning #{newobj}"
      return newobj
    else
      raise InvalidHostError
    end
  end

  JUMP_TABLE = {
    "ipinfodb" => Proc.new { |bot, ip| ipinfodb(bot, ip) },
    "geoiptool" => Proc.new { |bot, ip| geoiptool(bot, ip) },
  }

  def self.resolve(bot, hostname, api)
    raise InvalidHostError unless valid_host?(hostname)

    begin
      ip = Resolv.getaddress(hostname)
    rescue Resolv::ResolvError
      raise InvalidHostError
    end

    raise BadAPIError unless JUMP_TABLE.key?(api)

    return JUMP_TABLE[api].call(bot, ip)
  end
end

class Stack
  def initialize
    @hash = {}
  end

  def [](nick)
    @hash[nick] = [] unless @hash[nick]
    @hash[nick]
  end

  def has_nick?(nick)
    @hash.has_key?(nick)
  end

  def clear(nick)
    @hash.delete(nick)
  end
end

class GeoIpPlugin < Plugin
  Config.register Config::ArrayValue.new('geoip.sources',
      :default => [ "ipinfodb", "geoiptool" ],
      :desc => "Which API to use for lookups. Supported values: ipinfodb, geoiptool")
  Config.register Config::StringValue.new('geoip.ipinfodb_key',
      :default => "",
      :desc => "API key for the IPinfoDB geolocation service")

  def help(plugin, topic = '')
    "geoip [<user|hostname|ip>] => returns the geographic location of whichever has been given -- note: user can be anyone on the network"
  end

  def initialize
    super

    @stack = Stack.new
  end

  def whois(m)
    nick = m.whois[:nick].downcase

    # need to see if the whois reply was invoked by this plugin
    return unless @stack.has_nick?(nick)

    if m.target
      msg = host2output(m.target.host, m.target.nick)
    else
      msg = "no such user on "+@bot.server.hostname.split(".")[-2]
    end
    @stack[nick].each do |source|
      @bot.say source, msg
    end

    @stack.clear(nick)
  end

  def geoip(m, params)
    if params.empty?
      m.reply host2output(m.source.host, m.source.nick)
    else
      if m.replyto.class == Channel

        # check if there is an user on the channel with nick same as input given
        user = m.replyto.users.find { |usr| usr.nick == params[:input] }

        if user
          m.reply host2output(user.host, user.nick)
          return
        end
      end

      # input is a host name or an IP
      if GeoIP::valid_host?(params[:input])
         m.reply host2output(params[:input])

      # assume input is a nick
      elsif params[:input] !~ /\./
        nick = params[:input].downcase

        @stack[nick] << m.replyto
        @bot.whois(nick)
      else
        m.reply "invalid input"
      end
    end
  end

  def host2output(host, nick=nil)
    return "127.0.0.1 could not be res.. wait, what?" if host == "127.0.0.1"

    geo = {:country => ""}
    begin
      apis = @bot.config['geoip.sources']
      apis.compact.each { |api|
        geo = GeoIP::resolve(@bot, host, api)
        if geo and geo[:country] != ""
          break
        end
      }
    rescue GeoIP::InvalidHostError, RuntimeError
      if nick
        return _("%{nick}'s location could not be resolved") % { :nick => nick }
      else
        return _("%{host} could not be resolved") % { :host => host }
      end
    rescue GeoIP::BadAPIError
      return _("The owner configured me to use an API that doesn't exist, bug them!")
    end

    location = []
    location << geo[:city] unless geo[:city].nil_or_empty?
    location << geo[:region] unless geo[:region].nil_or_empty? or geo[:region] == geo[:city]
    location << geo[:country] unless geo[:country].nil_or_empty?

    if nick
      res = _("%{nick} is from %{location}")
    else
      res = _("%{host} is located in %{location}")
    end

    return res % {
      :nick => nick,
      :host => host,
      :location => location.join(', ')
    }
  end
end

plugin = GeoIpPlugin.new
plugin.map "geoip [:input]", :action => 'geoip', :thread => true
