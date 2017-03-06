require 'cinch'
require 'sqlite3'
require 'rack'
require 'json'

class CircularBuffer
        include Enumerable

        def initialize(n)
                @n = n
                @i = 0
                @xs = []
        end

        def <<(x)
                if @xs.length == @n
                        @xs[@i] = x
                        @i = (@i + 1) % @n
                else
                        @xs.push(x)
                end
        end

        def each
                (@i...@n).each { |i| yield @xs[i] }
                (0...@i).each  { |i| yield @xs[i] }
        end

        def length
                @xs.length
        end

        def [](i)
                @xs[(i + @i) % @n]
        end
end

class QuoteBot
        def initialize
                @db = SQLite3::Database.new 'quotes.db'
                @msg_id = (@db.execute('select max(id) from messages;')[0][0] or -1) + 1
                @grab_id = (@db.execute('select max(id) from grabs;')[0][0] or -1) + 1
                @chans = {}
                qb = self
                @bot = Cinch::Bot.new do
                        configure do |c|
                                c.server = 'irc.snoonet.org'
                                c.port = 6667
                                c.nick = 'quotebot'
                                c.user = 'quotebot'
                                c.channels = ['##qb-test']
                        end

                        on :join do |m|
                                if m.user.nick == bot.nick
                                        m.channel.send("Hello, #{m.channel.to_s}!")
                                        qb.join(m.channel.to_s)
                                end
                        end

                        on :message do |m|
                                match = m.message.match(/^quotebot[^a-zA-Z0-9_]+([a-z]+)(.*)$/)
                                debug match.to_s
                                if match.nil?
                                        debug 'adding message to channel'
                                        qb.msg(m)
                                else
                                        arg = match[2].strip
                                        debug "command = '#{match[1]}', arg = '#{arg}'"
                                        case match[1]
                                        when 'grab'
                                                debug 'calling grab()...'
                                                qb.grab(m, arg)
                                        when 'random'
                                                qb.random(m, arg)
                                        end
                                end
                        end
                end
        end

        def join(c)
                @chans[c] = CircularBuffer.new(500)
        end

        def msg(m)
                @chans[m.channel.to_s] << m
        end

        def create_grab(m, msgs)
                @db.execute(
                        'insert into grabs values (?, ?, ?, ?)',
                        [@grab_id, Time.now.to_i, m.user.nick, m.channel.to_s]
                )

                msgs.each_with_index do |msg, i|
                        @db.execute(
                                'insert into messages values (?, ?, ?, ?, ?)',
                                [@msg_id + i, msg.time.to_i, msg.action? ? 1 : 0, msg.user.nick, msg.message]
                        )
                        @db.execute(
                                'insert into map values (?, ?, ?)',
                                [@msg_id + i, @grab_id, i]
                        )
                end

                @msg_id += msgs.length
                @grab_id += 1
        end

        def grab(m, arg)
                parts = arg.split(' + ').map do |s|
                        match = s.strip.match(/^(\S+)(.*)$/)
                        [match[1], match[2].strip]
                end

                nick, msg = parts.shift
                msgs = @chans[m.channel.to_s]

                puts "nick = #{nick}"
                puts "msg = #{msg}"

                i = msgs.length - 1
                while i >= 0 && (msgs[i].user.nick != nick || !msgs[i].message.include?(msg))
                        puts "skipping #{msgs[i].message}"
                        i -= 1
                end

                if i < 0
                        m.reply("No message from #{nick} found containing '#{msg}'.")
                        return
                end

                keep = [msgs[i]]

                parts.each do |p|
                        nick, msg = p
                        while i < msgs.length && (msgs[i].user.nick != nick || !msgs[i].message.include?(msg))
                                i += 1
                        end
                        if i == msgs.length
                                m.reply("No message from #{nick} found containing '#{msg}'.")
                                return
                        end
                        keep << msgs[i]
                end

                id = create_grab(m, keep)

                m.reply("#{m.user.nick}: Grab successful! View it online at http://longjmp.org/grabs/#{id}");
        end

        def random(m, arg)

        end

        def get_grab(id)
                query = <<-SQL
                select * from grabs
                  inner join map on map.grab_id = grabs.id
                  inner join messages on map.message_id = messages.id
                where grabs.id = ?
                order by map.i asc;
                SQL

                rows = @db.execute(query, [id])
                puts "rows = #{rows}"

                return nil if rows.empty?

                r = {
                        'time'     => rows[0][1],
                        'author'   => rows[0][2],
                        'channel'  => rows[0][3],
                        'messages' => []
                }

                rows.each do |row|
                        r['messages'] << {
                                'time'    => row[8],
                                'action'  => row[9],
                                'nick'    => row[10],
                                'message' => row[11]
                        }
                end

                return r
        end

        def start
                http = Thread.new do
                        app = Proc.new do |env|
                                g = env['REQUEST_PATH'].match(/^\/grabs\/([0-9]+)\.json$/)[1]
                                g = get_grab(g.to_i) if !g.nil?
                                puts "g = #{g}"
                                g ? ['200', {'Content-Type' => 'application/json'}, [JSON.dump(g)]]
                                  : ['404', {'Content-Type' => 'text/html'}, ['you fucked up']]
                        end

                        Rack::Handler::WEBrick.run app, :Port => 9292
                end
                #@bot.start
                http.join
        end
end

QuoteBot.new.start
