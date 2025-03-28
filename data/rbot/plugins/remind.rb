class RemindPlugin < Plugin
  # read a time in string format, turn it into "seconds from now".
  # example formats handled are "5 minutes", "2 days", "five hours",
  # "11:30", "15:45:11", "one day", etc.
  #
  # Throws:: RunTimeError "invalid time string" on parse failure
  def timestr_offset(timestr)
    Utils.parse_time_offset(timestr)
  end

  class UnparsedPeriodError < RuntimeError ; end
  class NegativePeriodError < RuntimeError ; end
  class ShortRepeatError < RuntimeError ; end

  def initialize
    super
    @reminders = Hash.new
  end
  def cleanup
    @reminders.each_value {|v|
      v.each_value {|vv|
        @bot.timer.remove(vv)
      }
    }
    @reminders.clear
    super
  end
  def help(plugin, topic = '')
    "reminder plugin: remind <who> [about] <message> in <time>, remind <who> [about] <message> every <time>, remind <who> [about] <message> at <time>, remind <who> no more [about] <message>, remind <who> no more. Generally <who> should be 'me', but you can remind others (nick or channel) if you have remind_others auth"
  end
  def add_reminder(m, who, subject, timestr, repeat=false)
    begin
      period = timestr_offset(timestr)
    rescue RuntimeError
      raise UnparsedPeriodError
    end
    raise NegativePeriodError if period <= 0
    raise ShortRepeatError if period < 30 && repeat

    if(period <= 0)
      return "that time is in the past! (#{timestr})"
    end
    if(period < 30 && repeat)
      return
    end
    if(!@reminders.has_key?(who))
      @reminders[who] = Hash.new
    elsif(@reminders[who].has_key?(subject))
      del_reminder(who, subject)
    end

    if(repeat)
      @reminders[who][subject] = @bot.timer.add(period) {
        tstr = (Time.now + period).strftime("%H:%M:%S")
        @bot.say who, "repeat reminder (next at #{tstr}): #{subject}"
      }
    else
      @reminders[who][subject] = @bot.timer.add_once(period) {
        tstr = Time.now.strftime("%H:%M:%S")
        @bot.say who, "reminder (#{tstr}): #{subject}"
      }
    end

    m.okay
  end

  def del_reminder(who, subject=nil)
    if(subject)
      if(@reminders.has_key?(who) && @reminders[who].has_key?(subject))
        @bot.timer.remove(@reminders[who][subject])
        @reminders[who].delete(subject)
        return true
      else
        return false
      end
    else
      if(@reminders.has_key?(who))
        @reminders[who].each_value {|v|
          @bot.timer.remove(v)
        }
        @reminders.delete(who)
        return true
      else
        return false
      end
    end
  end
  def remind(m, params)
    who = params.has_key?(:who) ? params[:who] : m.sourcenick
    string = params[:string].to_s
    debug "in remind, string is: #{string}"
    tried = []

    begin
      if !tried.include?(:in) and string =~ /^(.*)\s+in\s+(.*)$/
        subject = $1
        period = $2
        tried << :in
        add_reminder(m, who, subject, period)
        return true
      end

      if !tried.include?(:every) and string =~ /^(.*)\s+every\s+(.*)$/
        subject = $1
        period = $2
        tried << :every
        add_reminder(m, who, subject, period, true)
        return true
      end

      if !tried.include?(:at) and string =~ /^(.*)\s+at\s+(.*)$/
        subject = $1
        time = $2
        tried << :at
        add_reminder(m, who, subject, time)
        return true
      end

      usage(m)
      return false
    rescue NegativePeriodError
      m.reply "that time is in the past! (#{timestr})"
      return false
    rescue ShortRepeatError
      m.reply "repeats of less than 30 seconds are forbidden"
      return false
    rescue UnparsedPeriodError
      retry
    end

  end

  def no_more(m, params)
    who = params.has_key?(:who) ? params[:who] : m.sourcenick
    deleted = params.has_key?(:string) ?
              del_reminder(who, params[:string].to_s) : del_reminder(who)
    if deleted
      m.okay
    else
      m.reply "but I wasn't going to :/"
    end
  end
end
plugin = RemindPlugin.new

plugin.default_auth('other', false)

plugin.map 'remind me no more', :action => 'no_more'
plugin.map 'remind me no more [about] *string', :action => 'no_more'
plugin.map 'remind me [about] *string'
plugin.map 'remind :who no more', :auth_path => 'other', :action => 'no_more'
plugin.map 'remind :who no more [about] *string', :auth_path => 'other', :action => 'no_more'
plugin.map 'remind :who [about] *string', :auth_path => 'other'

