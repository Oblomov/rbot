#-- vim:sw=2:et
#++
#
# :title: Google and Wikipedia search plugin for rbot
#
# Author:: Tom Gilbert (giblet) <tom@linuxbrit.co.uk>
# Author:: Giuseppe "Oblomov" Bilotta <giuseppe.bilotta@gmail.com>
#
# Copyright:: (C) 2002-2005 Tom Gilbert
# Copyright:: (C) 2006 Tom Gilbert, Giuseppe Bilotta
# Copyright:: (C) 2006-2007 Giuseppe Bilotta

# TODO:: use lr=lang_<code> or whatever is most appropriate to let google know
#        it shouldn't use the bot's location to find the preferred language
# TODO:: support localized uncyclopedias -- not easy because they have different names
#        for most languages

GOOGLE_SEARCH = "https://www.google.com/search?hl=en&oe=UTF-8&ie=UTF-8&gbv=1&q="
GOOGLE_WAP_SEARCH = "https://www.google.com/m/search?hl=en&ie=UTF-8&gbv=1&q="
GOOGLE_WAP_LINK = /<a\s+href="\/url\?(q=[^"]+)"[^>]*>\s*<div[^>]*>(.*?)\s*<\/div>/im
GOOGLE_CALC_RESULT = />Calculator<\/span>(?:<\/?[^>]+>\s*)+([^<]+)/ 
GOOGLE_XPATH_DEF = "//img[@id='flex_text_audio_icon_chunk']/../../../../div[3]//text()"
DDG_API_SEARCH = "http://api.duckduckgo.com/?format=xml&no_html=1&skip_disambig=1&no_redirect=0&q="
WOLFRAM_API_SEARCH = "http://api.wolframalpha.com/v2/query?input=%{terms}&appid=%{key}&format=plaintext" +
           "&scantimeout=3.0&podtimeout=4.0&formattimeout=8.0&parsetimeout=5.0" +
           "&excludepodid=SeriesRepresentations:*"
WOLFRAM_API_KEY = "9RW6XR-QTL2JT7J4W"

class SearchPlugin < Plugin
  Config.register Config::IntegerValue.new('duckduckgo.hits',
    :default => 3, :validate => Proc.new{|v| v > 0},
    :desc => "Number of hits to return from searches")
  Config.register Config::IntegerValue.new('duckduckgo.first_par',
    :default => 0,
    :desc => "When set to n > 0, the bot will return the first paragraph from the first n search hits")
  Config.register Config::IntegerValue.new('google.hits',
    :default => 3,
    :desc => "Number of hits to return from Google searches")
  Config.register Config::IntegerValue.new('google.first_par',
    :default => 0,
    :desc => "When set to n > 0, the bot will return the first paragraph from the first n search hits")
  Config.register Config::IntegerValue.new('wikipedia.hits',
    :default => 3,
    :desc => "Number of hits to return from Wikipedia searches")
  Config.register Config::IntegerValue.new('wikipedia.first_par',
    :default => 1,
    :desc => "When set to n > 0, the bot will return the first paragraph from the first n wikipedia search hits")

  def help(plugin, topic = '')
    case topic
    when "ddg"
      "Use '#{topic} <string>' to return a search or calculation from " +
      "DuckDuckGo. Use #{topic} define <string> to return a definition."
    when "search", "google"
      "#{topic} <string> => search google for <string>"
    when "gcalc"
      "gcalc <equation> => use the google calculator to find the answer to <equation>"
    when "gdef"
      "gdef <term(s)> => use the google define mechanism to find a definition of <term(s)>"
    when "wa"
      "wa <string> => searches WolframAlpha for <string>"
    when "wp"
      "wp [<code>] <string> => search for <string> on Wikipedia. You can select a national <code> to only search the national Wikipedia"
    when "unpedia"
      "unpedia <string> => search for <string> on Uncyclopedia"
    else
      "search <string> (or: google <string>) => search google for <string> | ddg <string> to search DuckDuckGo | wp <string> => search for <string> on Wikipedia | wa <string> => search for <string> on WolframAlpha | unpedia <string> => search for <string> on Uncyclopedia"
    end
  end

  def duckduckgo(m, params)
    what = params[:words].to_s
    terms = CGI.escape what
    url = DDG_API_SEARCH + terms

    hits = @bot.config['duckduckgo.hits']
    first_pars = params[:firstpar] || @bot.config['duckduckgo.first_par']
    single = params[:lucky] || (hits == 1 and first_pars == 1)

    begin
      feed = @bot.httputil.get(url)
      raise unless feed
    rescue => e
      m.reply "error duckduckgoing for #{what}"
      return
    end

    xml = REXML::Document.new feed
    heading = xml.elements['//Heading/text()'].to_s
    # answer is returned for calculations
    answer = xml.elements['//Answer/text()'].to_s
    # abstract is returned for definitions etc
    abstract = xml.elements['//AbstractText/text()'].to_s
    abfrom = ""
    unless abstract.empty?
      absrc = xml.elements['//AbstractSource/text()'].to_s
      aburl = xml.elements['//AbstractURL/text()'].to_s
      unless absrc.empty? and aburl.empty?
        abfrom = " --"
        abfrom << " " << absrc unless absrc.empty?
        abfrom << " " << aburl unless aburl.empty?
      end
    end

    # but also definition (yes, you can have both, see e.g. printf)
    definition = xml.elements['//Definition/text()'].to_s
    deffrom = ""
    unless definition.empty?
      defsrc = xml.elements['//Definition/@source/text()'].to_s
      defurl = xml.elements['//Definition/@url/text()'].to_s
      unless defsrc.empty? and defurl.empty?
        deffrom = " --"
        deffrom << " " << defsrc unless defsrc.empty?
        deffrom << " " << defurl unless defurl.empty?
      end
    end

    if heading.empty? and answer.empty? and abstract.empty? and definition.empty?
      m.reply "no results"
      return
    end

    # if we got a one-shot answer (e.g. a calculation, return it)
    unless answer.empty?
      m.reply answer
      return
    end

    # otherwise, return the abstract, followed by as many hits as found
    unless heading.empty? or abstract.empty?
      m.reply "%{bold}%{heading}:%{bold} %{abstract}%{abfrom}" % {
        :bold => Bold, :heading => heading,
        :abstract => abstract, :abfrom => abfrom
      }
    end
    unless heading.empty? or definition.empty?
      m.reply "%{bold}%{heading}:%{bold} %{abstract}%{abfrom}" % {
        :bold => Bold, :heading => heading,
        :abstract => definition, :abfrom => deffrom
      }
    end
    # return zeroclick search results
    links, texts = [], []
    xml.elements.each("//Results/Result/FirstURL") { |element|
      links << element.text
      break if links.size == hits
    }
    return if links.empty?

    xml.elements.each("//Results/Result/Text") { |element|
      texts << " #{element.text}"
      break if links.size == hits
    }
    # TODO see treatment of `single` in google search

    single ||= (links.length == 1)
    pretty = []
    links.each_with_index do |u, i|
      t = texts[i]
      pretty.push("%{n}%{b}%{t}%{b}%{sep}%{u}" % {
        :n => (single ? "" : "#{i}. "),
        :sep => (single ? " -- " : ": "),
        :b => Bold, :t => t, :u => u
      })
    end

    result_string = pretty.join(" | ")

    # If we return a single, full result, change the output to a more compact representation
    if single
      fp = first_pars > 0 ? " --  #{Utils.get_first_pars(@bot, links, first_pars)}" : ""
      m.reply("Result for %{what}: %{string}%{fp}" % {
        :what => what, :string => result_string, :fp => fp
      }, :overlong => :truncate)
      return
    end

    m.reply "Results for #{what}: #{result_string}", :split_at => /\s+\|\s+/

    return unless first_pars > 0

    Utils.get_first_pars(@bot, urls, first_pars, :message => m)
  end

  def google(m, params)
    what = params[:words].to_s
    if what.match(/^define:/)
      return google_define(m, what, params)
    end

    searchfor = CGI.escape what
    # This method is also called by other methods to restrict searching to some sites
    if params[:site]
      site = "site:#{params[:site]}+"
    else
      site = ""
    end
    # It is also possible to choose a filter to remove constant parts from the titles
    # e.g.: "Wikipedia, the free encyclopedia" when doing Wikipedia searches
    filter = params[:filter] || ""

    url = GOOGLE_WAP_SEARCH + site + searchfor

    hits = params[:hits] || @bot.config['google.hits']
    hits = 1 if params[:lucky]

    first_pars = params[:firstpar] || @bot.config['google.first_par']

    single = params[:lucky] || (hits == 1 and first_pars == 1)

    begin
      wml = @bot.httputil.get(url)
      raise unless wml
    rescue => e
      m.reply "error googling for #{what}"
      return
    end
    results = wml.scan(GOOGLE_WAP_LINK)

    if results.length == 0
      m.reply "no results found for #{what}"
      return
    end

    results = results.map {|result|
      url = CGI::parse(Utils.decode_html_entities(result[0]))['q'].first
      title = Utils.decode_html_entities(result[1].gsub(/<\/?[^>]+>/, ''))
      [url, title] unless url.empty? or title.empty?
    }.reject {|item| not item}[0..hits]

    result_string = results.map {|url, title| "#{Bold}#{title}#{NormalText}: #{url}"}

    if params[:lucky]
      m.reply result_string.first
      Utils.get_first_pars(@bot, [results.map {|url, title| url}.first], first_pars, :message => m)
      return
    end

    m.reply "Results for #{what}: #{result_string.join(' | ')}", :split_at => /\s+\|\s+/

    return unless first_pars > 0

    Utils.get_first_pars(@bot, results.map {|url, title| url}, first_pars, :message => m)
  end

  def google_define(m, what, params)
    begin
      wml = @bot.httputil.get(GOOGLE_SEARCH + CGI.escape(what))
      raise unless wml
    rescue => e
      m.reply "error googling for #{what}"
      return
    end

    begin
      related_index = wml.index(/Related phrases:/, 0)
      raise unless related_index
      defs_index = wml.index(/Definitions of <b>/, related_index)
      raise unless defs_index
      defs_end = wml.index(/<input/, defs_index)
      raise unless defs_end
    rescue => e
      m.reply "no results found for #{what}"
      return
    end

    related = wml[related_index...defs_index]
    defs = wml[defs_index...defs_end]

    m.reply defs.ircify_html(:a_href => Underline), :split_at => (Underline + ' ')

  end

  def lucky(m, params)
    params.merge!(:lucky => true)
    google(m, params)
  end

  def gcalc(m, params)
    what = params[:words].to_s
    searchfor = CGI.escape(what)

    debug "Getting gcalc thing: #{searchfor.inspect}"
    url = GOOGLE_WAP_SEARCH + searchfor

    begin
      html = @bot.httputil.get(url)
    rescue => e
      m.reply "error googlecalcing #{what}"
      return
    end

    debug "#{html.size} bytes of html received"
    debug html

    candidates = html.match(GOOGLE_CALC_RESULT)
    debug "candidates: #{candidates.inspect}"

    if candidates.nil?
      m.reply "couldn't calculate #{what}"
      return
    end
    result = candidates[1].remove_nonascii

    debug "replying with: #{result.inspect}"
    m.reply result.ircify_html
  end

  def gdef(m, params)
    what = params[:words].to_s
    searchfor = CGI.escape("define " + what)

    debug "Getting gdef thing: #{searchfor.inspect}"
    url = GOOGLE_WAP_SEARCH + searchfor

    begin
      resp = @bot.httputil.get(url, resp: true)
    rescue => e
      m.reply "error googledefining #{what}"
      return
    end

    results = resp.xpath(GOOGLE_XPATH_DEF).map(&:content)

    if results.empty?
      m.reply "couldn't find a definition for #{what} on Google"
    else
      m.reply "#{results.first} -- #{results[1..-1].join(' ')}"
    end
  end

  def wolfram(m, params)
    what = params[:words].to_s
    terms = CGI.escape what
    url = WOLFRAM_API_SEARCH % {
      :terms => terms, :key => WOLFRAM_API_KEY
    }

    begin
      feed = @bot.httputil.get(url)
      raise unless feed
    rescue => e
      m.reply "error asking WolframAlfa about #{what}"
      return
    end
    debug feed

    xml = REXML::Document.new feed
    if xml.elements['/queryresult'].attributes['error'] == "true"
      m.reply xml.elements['/queryresult/error/text()'].to_s
      return
    end
    unless xml.elements['/queryresult'].attributes['success'] == "true"
      m.reply "no data available"
      return
    end
    answer_type, answer = [], []
    xml.elements.each("//pod") { |element|
      answer_type << element.attributes['title']
      answer << element.elements['subpod/plaintext'].text
    }
    # find the first answer that isn't nil,
    # starting on the second pod in the array
    n = 1
    answer[1..-1].each { |a|
      break unless a.nil?
      n += 1
    }
    if answer[n].nil?
      m.reply "no results"
      return
    end
    # strip spaces, pipes, and line breaks
    sep = Bold + ' :: ' + Bold
    chars = [ [/\n/, sep], [/\t/, " "], [/\s+/, " "], ["|", "-"] ]
    chars.each { |c| answer[n].gsub!(c[0], c[1]) }
    m.reply answer_type[n] + sep + answer[n]
  end

  def wikipedia(m, params)
    lang = params[:lang]
    site = "#{lang.nil? ? '' : lang + '.'}wikipedia.org"
    debug "Looking up things on #{site}"
    params[:site] = site
    params[:filter] = / - Wikipedia.*$/
    params[:hits] = @bot.config['wikipedia.hits']
    params[:firstpar] = @bot.config['wikipedia.first_par']
    return google(m, params)
  end

  def unpedia(m, params)
    site = "uncyclopedia.org"
    debug "Looking up things on #{site}"
    params[:site] = site
    params[:filter] = / - Uncyclopedia.*$/
    params[:hits] = @bot.config['wikipedia.hits']
    params[:firstpar] = @bot.config['wikipedia.first_par']
    return google(m, params)
  end
end

plugin = SearchPlugin.new

plugin.map "ddg *words", :action => 'duckduckgo', :threaded => true
plugin.map "search *words", :action => 'google', :threaded => true
plugin.map "google *words", :action => 'google', :threaded => true
plugin.map "lucky *words", :action => 'lucky', :threaded => true
plugin.map "gcalc *words", :action => 'gcalc', :threaded => true
plugin.map "gdef *words", :action => 'gdef', :threaded => true
plugin.map "wa *words", :action => 'wolfram', :threaded => true
plugin.map "wp :lang *words", :action => 'wikipedia', :requirements => { :lang => /^\w\w\w?$/ }, :threaded => true
plugin.map "wp *words", :action => 'wikipedia', :threaded => true
plugin.map "unpedia *words", :action => 'unpedia', :threaded => true
