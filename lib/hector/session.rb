module Hector
  class Session
    attr_reader :nickname, :realname, :connected, :connection, :identity

    class << self
      def nicknames
        sessions.keys
      end

      def find(nickname)
        sessions[normalize(nickname)]
      end

      def create(nickname, connection, identity, realname)
        if find(nickname)
          raise NicknameInUse, nickname
        else
          new(nickname, connection, identity, realname).tap do |session|
            sessions[normalize(nickname)] = session
          end
        end
      end

      def rename(from, to)
        if find(to)
          raise NicknameInUse, to
        else
          find(from).tap do |session|
            delete(from)
            sessions[normalize(to)] = session
          end
        end
      end

      def delete(nickname)
        sessions.delete(normalize(nickname))
      end

      def broadcast_to(sessions, command, *args)
        except = args.last.delete(:except) if args.last.is_a?(Hash)
        sessions.each do |session|
          session.respond_with(command, *args) unless session == except
        end
      end

      def normalize(nickname)
        if nickname =~ /^\w[\w-]{0,15}$/
          nickname.downcase
        else
          raise ErroneousNickname, nickname
        end
      end

      def reset!
        @sessions = nil
      end

      protected
        def sessions
          @sessions ||= {}
        end
    end

    def initialize(nickname, connection, identity, realname)
      @nickname = nickname
      @connection = connection
      @identity = identity
      @realname = realname
      @connected = Time.new.to_i
      @lastmessage = @connected
    end

    def receive(request)
      @request = request
      if respond_to?(request.event_name)
        send(request.event_name)
      end
    ensure
      @request = nil
    end

    def idle
      Time.new.to_i - @lastmessage
    end

    def welcome
      respond_with("001", nickname, :text => "Welcome to IRC")
      respond_with("422", :text => "MOTD File is missing")
    end

    def on_privmsg
      deliver_message_as(:privmsg)
    end

    def on_notice
      deliver_message_as(:notice)
    end

    def deliver_message_as(message_type)
      destination, text = request.args.first, request.text
      @lastmessage = Time.new.to_i
      
      if channel?(destination)
        on_channel_message(message_type, destination, text)
      else
        on_session_message(message_type, destination, text)
      end
    end

    def on_channel_message(message_type, channel_name, text)
      if channel = Channel.find(channel_name)
        if channel.has_session?(self)
          channel.broadcast(message_type, channel.name, :source => source, :text => text, :except => self)
        else
          raise CannotSendToChannel, channel_name
        end
      else
        raise NoSuchNickOrChannel, channel_name
      end
    end

    def on_session_message(message_type, nickname, text)
      if session = Session.find(nickname)
        session.respond_with(message_type, nickname, :source => source, :text => text)
      else
        raise NoSuchNickOrChannel, nickname
      end
    end

    def on_join
      Channel.find_or_create(request.args.first).join(self)
    end

    def on_part
      Channel.find(request.args.first).part(self, request.text)
    end

    def on_names
      Channel.find(request.args.first).respond_to_names(self)
    end

    def on_topic
      channel = Channel.find(request.args.first)

      if request.args.length > 1
        channel.change_topic(self, request.text)
      else
        channel.respond_to_topic(self)
      end
    end

    def on_ping
      respond_with(:pong, :source => "hector.irc", :text => request.text)
    end

    def on_whois
      nickname = request.args.first
      if session = Session.find(nickname)
        respond_to_whois_for(self.nickname, session)
      else
        # Can't raise NoSuchNickOrChannel because we also need to return
        # the 318 below.
        respond_with("401", self.nickname, nickname, :text => "No such nick/channel")
      end
      respond_with("318", self.nickname, nickname, "End of /WHOIS list.")
    end

    def on_who
      destination = request.args.first

      if channel?(destination)
        on_channel_who(destination)
      else
        on_session_who(destination)
      end

      respond_with("315", destination, :text => "End of /WHO list.")
    end

    def on_channel_who(channel_name)
      if channel = Channel.find(channel_name)
        respond_to_who_for(channel_name, channel.sessions)
      end
    end

    def on_session_who(nickname)
      if session = Session.find(nickname)
        respond_to_who_for("*", [session])
      end
    end

    def on_nick
      rename(request.args.first)
    end

    def on_quit
      @quit_message = "Quit: #{request.text}"
      connection.close_connection
    end

    def rename(new_nickname)
      Session.rename(nickname, new_nickname)
      broadcast(:nick, new_nickname, :source => nickname)
      @nickname = new_nickname
    end

    def destroy
      deliver_quit_message
      leave_all_channels
      self.class.delete(nickname)
    end

    def respond_with(*args)
      connection.respond_with(*args)
    end

    def broadcast(command, *args)
      Session.broadcast_to(peer_sessions, command, *args)
    end

    def channels
      Channel.find_all_for_session(self)
    end

    def peer_sessions
      [self, *channels.map { |channel| channel.sessions }.flatten].uniq
    end

    def quit_message
      @quit_message || "Connection closed"
    end

    def source
      "#{nickname}!#{identity.username}@hector"
    end

    def who
      "#{identity.username} hector.irc hector.irc #{nickname} H :0 #{realname}"
    end

    def whois
      "#{nickname} #{identity.username} hector.irc * :#{realname}"
    end

    protected
      attr_reader :request

      def channel?(destination)
        destination =~ /^#/
      end

      def deliver_quit_message
        broadcast(:quit, :source => source, :text => quit_message, :except => self)
        respond_with(:error, :text => "Closing Link: #{nickname}[hector] (#{quit_message})")
      end

      def leave_all_channels
        channels.each do |channel|
          channel.remove(self)
        end
      end

      def respond_to_who_for(destination, sessions)
        sessions.each do |session|
          respond_with("352", destination, session.who)
        end
      end

      def respond_to_whois_for(destination, session)
        respond_with("311", destination, session.nickname, session.whois)
        unless channels.empty?
          respond_with("319", destination, session.nickname, :text => channels.map { |channel| channel.name }.join(" "))
        end
        respond_with("312", destination, session.nickname, 'hector.irc', :text => 'Hard Hecting')
        respond_with("317", destination, session.nickname, session.idle, session.connected, :text => "seconds idle, signon time")
      end
  end
end
