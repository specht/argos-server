require 'active_support'
require 'active_support/core_ext/time/zones'
require 'base64'
require 'curb'
require 'date'
require 'digest/sha1'
require 'faye/websocket'
require 'htmlentities'
require 'json'
require 'kramdown'
require 'open3'
require 'set'
require 'sinatra/base'
require 'time'
require 'timeout'
require 'uri'
require 'uri/query_params'
require 'yaml'

require '/credentials.rb'

DEVELOPMENT = (WEB_ROOT == 'http://localhost:8035')

if DEVELOPMENT
    STDERR.puts '*' * 40
    STDERR.puts "ATTENTION THIS IS RUNNING IN DEV"
    STDERR.puts '*' * 40
end

def dtn
    DateTime.now
end

class RandomTag
    BASE_31_ALPHABET = '0123456789bcdfghjklmnpqrstvwxyz'
    def self.to_base31(i)
        result = ''
        while i > 0
            result += BASE_31_ALPHABET[i % 31]
            i /= 31
        end
        result
    end

    def self.generate(length = 12)
        self.to_base31(SecureRandom.hex(length).to_i(16))[0, length]
    end
end

TIME_ZONE = 'Europe/Berlin'
ENV["TZ"] = TIME_ZONE
Time.zone = TIME_ZONE

def parse_markdown(s)
    s ||= ''
    Kramdown::Document.new(s, :smart_quotes => %w{sbquo lsquo bdquo ldquo}).to_html.strip
end

class Main < Sinatra::Base
    configure do
        set :show_exceptions, false
    end

    configure do
        @@compiled_files = {}
        @@available_pins = (0...10000).map { |i| sprintf('%04d', i) }.shuffle
        STDERR.puts "Server is up and running!"
    end

    def assert(condition, message = 'assertion failed')
        raise message unless condition
    end

    def test_request_parameter(data, key, options)
        type = ((options[:types] || {})[key]) || String
        assert(data[key.to_s].is_a?(type), "#{key.to_s} is a #{type}")
        if type == String
            assert(data[key.to_s].size <= (options[:max_value_lengths][key] || options[:max_string_length]), 'too_much_data')
        end
    end

    def parse_request_data(options = {})
        options[:max_body_length] ||= 512
        options[:max_string_length] ||= 512
        options[:required_keys] ||= []
        options[:optional_keys] ||= []
        options[:max_value_lengths] ||= {}
        data_str = request.body.read(options[:max_body_length]).to_s
        @latest_request_body = data_str.dup
        begin
            assert(data_str.is_a? String)
            assert(data_str.size < options[:max_body_length], 'too_much_data')
            data = JSON::parse(data_str)
            @latest_request_body_parsed = data.dup
            result = {}
            options[:required_keys].each do |key|
                assert(data.include?(key.to_s))
                test_request_parameter(data, key, options)
                result[key.to_sym] = data[key.to_s]
            end
            options[:optional_keys].each do |key|
                if data.include?(key.to_s)
                    test_request_parameter(data, key, options)
                    result[key.to_sym] = data[key.to_s]
                end
            end
            result
        rescue
            STDERR.puts "Request was:"
            STDERR.puts data_str
            raise
        end
    end

    before '*' do
        path = request.env['REQUEST_PATH']
        path = path[3, path.size - 3] if path[0, 4] == '/ws/'
        @latest_request_body = nil
        @latest_request_body_parsed = nil
    end

    after '/api/*' do
        if @respond_content
            response.body = @respond_content
            response.headers['Content-Type'] = @respond_mimetype
        else
            @respond_hash ||= {}
            response.body = @respond_hash.to_json
        end
    end

    def respond(hash = {})
        @respond_hash = hash
    end

    def respond_raw_with_mimetype(content, mimetype)
        @respond_content = content
        @respond_mimetype = mimetype
    end

    @@clients = {}
    @@client_info = {}
    @@games = {}
    @@game_pin_for_host_sid = {}
    @@expected_pins = {}

    def htmlentities(s)
        @html_entities_coder ||= HTMLEntities.new
        @html_entities_coder.encode(s)
    end

    error RuntimeError do
        respond(:error => env['sinatra.error'])
    end

    def send_to_client(client_id, data)
        if @@clients[client_id]
            @@clients[client_id].send(data.to_json)
        end
    end

    def print_stats
        STDERR.puts "clients: #{@@clients.size}, games: #{@@games.size}, available pins: #{@@available_pins.size}"
    end

    def send_game_stats(game_pin)
        ids = [@@games[game_pin][:mod]]
        ids += @@games[game_pin][:displays].to_a
        ids.each do |cid|
            data = {
                :command => 'update_game_stats',
                :display_count => @@games[game_pin][:displays].size,
                :participant_count => @@games[game_pin][:participants].size,
                :non_rejected_submissions => @@games[game_pin][:non_rejected_submissions].size,
                :task_running => @@games[game_pin][:task_running],
                :show_index => @@games[game_pin][:show_index]
            }
            if @@games[game_pin][:displays].include?(cid) && @@games[game_pin][:show_index]
                data[:show_png] = @@games[game_pin][:png_for_sha1][@@games[game_pin][:submissions][@@games[game_pin][:show_index]]]
            end
            send_to_client(cid, data)
        end
    end

    def remove_game(game_pin)
        @@games[game_pin][:displays].each do |cid|
            @@clients[cid].close()
        end
        @@games[game_pin][:participants].each do |cid|
            @@clients[cid].close()
        end
        @@expected_pins.delete(@@games[game_pin][:display_pin])
        @@expected_pins.delete(@@games[game_pin][:participant_pin])
        @@expected_pins.delete(game_pin)
        @@available_pins << @@games[game_pin][:display_pin]
        @@available_pins << @@games[game_pin][:participant_pin]
        @@available_pins << game_pin
        sid = @@games[game_pin][:sid]
        @@game_pin_for_host_sid.delete(sid)
        @@games.delete(game_pin)
    end

    options '/ws/*' do
        response.headers['Access-Control-Allow-Origin'] = "https://argos.gymnasiumsteglitz.de"
    end

    get '/ws' do
        response.headers['Access-Control-Allow-Origin'] = "https://argos.gymnasiumsteglitz.de"
        if Faye::WebSocket.websocket?(request.env)
            ws = Faye::WebSocket.new(request.env)

            ws.on(:open) do |event|
                client_id = request.env['HTTP_SEC_WEBSOCKET_KEY']
                ws.send({:hello => 'world'})
                @@clients[client_id] = ws
                print_stats()
            end

            ws.on(:close) do |event|
                client_id = request.env['HTTP_SEC_WEBSOCKET_KEY']
                if @@client_info[client_id]
                    if @@client_info[client_id][:role] == :host
                        # do nothing so that the host will be able to re-connect
                    elsif @@client_info[client_id][:role] == :display
                        # display has disconnected
                        game_pin = @@client_info[client_id][:game_pin]
                        begin
                            @@games[game_pin][:displays].delete(client_id)
                            send_game_stats(game_pin)
                        rescue
                        end
                    elsif @@client_info[client_id][:role] == :participant
                        # participant has disconnected
                        game_pin = @@client_info[client_id][:game_pin]
                        begin
                            @@games[game_pin][:participants].delete(client_id)
                            send_game_stats(game_pin)
                        rescue
                        end
                    end
                end
                @@clients.delete(client_id) if @@clients.include?(client_id)
                print_stats()
            end

            ws.on(:message) do |msg|
                client_id = request.env['HTTP_SEC_WEBSOCKET_KEY']
                begin
                    request = {}
                    unless msg.data.empty?
                        request = JSON.parse(msg.data)
                    end
                    if request['hello'] == 'world'
                        ws.send({:status => 'welcome'}.to_json)
                    elsif request['command'] == 'new'
                        # check for stale games and remove them
                        remove_game_pins = []
                        @@games.each_pair do |game_pin, game|
                            if Time.now.to_i > game[:last_activity] + 60 * 60
                                remove_game_pins << game_pin
                            end
                        end
                        remove_game_pins.each do |game_pin|
                            remove_game(game_pin)
                        end

                        assert(@@available_pins.size >= 3)
                        game_pin = @@available_pins.shift
                        participant_pin = @@available_pins.shift
                        display_pin = @@available_pins.shift
                        sid = RandomTag.generate(24)
                        @@games[game_pin] = {
                            :mod => client_id,
                            :participant_pin => participant_pin,
                            :display_pin => display_pin,
                            :displays => Set.new(),
                            :participants => Set.new(),
                            :submissions => [],
                            :png_for_sha1 => {},
                            :client_id_for_submission_index => {},
                            :non_rejected_submissions => Set.new(),
                            :task_running => false,
                            :sid => sid,
                            :last_activity => Time.now.to_i
                        }
                        @@game_pin_for_host_sid[sid] = game_pin
                        @@client_info[client_id] = {
                            :role => :host,
                            :game_pin => game_pin
                        }
                        @@expected_pins[display_pin] = { :type => :display, :game_pin => game_pin }
                        @@expected_pins[participant_pin] = { :type => :participant, :game_pin => game_pin }
                        ws.send({:command => :become_host, :display_pin => display_pin, :participant_pin => participant_pin, :sid => sid}.to_json)
                        STDERR.puts @@expected_pins.to_yaml
                        print_stats
                    elsif request['command'] == 'sid'
                        # re-join game as host
                        game_pin = @@game_pin_for_host_sid[request['sid']]
                        assert(!(game_pin.nil?))
                        @@games[game_pin][:last_activity] = Time.now.to_i
                        @@games[game_pin][:mod] = client_id
                        @@client_info[client_id] = {
                            :role => :host,
                            :game_pin => game_pin
                        }
                        data = {}
                        send_to_client(client_id, {
                            :command => :rejoin_with_sid,
                            :game_pin => game_pin,
                            :display_count => @@games[game_pin][:displays].size,
                            :participant_count => @@games[game_pin][:participants].size,
                            :non_rejected_submissions => @@games[game_pin][:non_rejected_submissions].size,
                            :task_running => @@games[game_pin][:task_running],
                            :base64_list => @@games[game_pin][:submissions].map do |sha1|
                                @@games[game_pin][:png_for_sha1][sha1]
                            end
                        })
                    elsif request['command'] == 'pin'
                        pin = request['pin']
                        unless @@expected_pins.include?(pin)
                            send_to_client(client_id, {
                                :command => :wrong_pin
                            })
                        end
                        assert(@@expected_pins.include?(pin))
                        game_pin = @@expected_pins[pin][:game_pin]
                        if @@expected_pins[pin][:type] == :display
                            unless @@games[game_pin][:displays].empty?
                                send_to_client(client_id, {
                                    :command => :wrong_pin
                                })
                                raise 'oops'
                            end
                            @@games[game_pin][:displays] << client_id
                            @@client_info[client_id] = {
                                :role => :display,
                                :game_pin => game_pin
                            }
                            send_to_client(client_id, {
                                :command => :become_display,
                                :participant_pin => @@games[game_pin][:participant_pin]
                            })
                            send_game_stats(game_pin)
                        elsif @@expected_pins[pin][:type] == :participant
                            @@games[game_pin][:participants] << client_id
                            @@client_info[client_id] = {
                                :role => :participant,
                                :game_pin => game_pin
                            }
                            send_to_client(client_id, {
                                :command => :become_participant
                            })
                            send_game_stats(game_pin)
                        end
                        print_stats
                    elsif request['command'] == 'new_task'
                        game_pin = @@client_info[client_id][:game_pin]
                        @@games[game_pin][:last_activity] = Time.now.to_i
                        @@games[game_pin][:participants].each do |cid|
                            send_to_client(cid, {:command => :new_task})
                        end
                        @@games[game_pin][:submissions] = []
                        @@games[game_pin][:png_for_sha1] = {}
                        @@games[game_pin][:client_id_for_submission_index] = {}
                        @@games[game_pin][:non_rejected_submissions] = Set.new()
                        @@games[game_pin][:task_running] = true
                        send_game_stats(game_pin)
                    elsif request['command'] == 'end_task'
                        game_pin = @@client_info[client_id][:game_pin]
                        @@games[game_pin][:task_running] = false
                        send_game_stats(game_pin)
                    elsif request['command'] == 'show'
                        game_pin = @@client_info[client_id][:game_pin]
                        @@games[game_pin][:last_activity] = Time.now.to_i
                        @@games[game_pin][:show_index] = request['index']
                        send_game_stats(game_pin)
                    elsif request['command'] == 'png'
                        base64 = request['png']
                        png = Base64.decode64(base64)
                        sha1 = Digest::SHA1.hexdigest(png)[0, 16]
                        game_pin = @@client_info[client_id][:game_pin]
                        url = "#{WEB_ROOT}/gen/#{sha1}.png"
                        index = @@games[game_pin][:submissions].size
                        @@games[game_pin][:submissions] << sha1
                        @@games[game_pin][:png_for_sha1][sha1] = base64
                        @@games[game_pin][:client_id_for_submission_index][index] = client_id
                        @@games[game_pin][:non_rejected_submissions] << index
                        send_game_stats(game_pin)
                        send_to_client(@@games[game_pin][:mod], {:command => :submission, :base64 => base64})
                    elsif request['command'] == 'react'
                        game_pin = @@client_info[client_id][:game_pin]
                        reaction = request['reaction']
                        index = request['index']
                        cid = @@games[game_pin][:client_id_for_submission_index][index]
                        send_to_client(cid, {:command => 'react', :reaction => reaction})
                        if reaction == 'reject'
                            @@games[game_pin][:non_rejected_submissions].delete(index)
                            send_game_stats(game_pin)
                        end
                    elsif request['command'] == 'remove_game'
                        game_pin = @@client_info[client_id][:game_pin]
                        remove_game(game_pin)
                    end
                rescue StandardError => e
                    STDERR.puts e
                end
            end
            ws.rack_response
        end
    end

    get '/api/sid/:sid' do
        sid = params['sid']
        if @@game_pin_for_host_sid[sid]
            status 200
        else
            status 404
        end
    end

    run! if app_file == $0
end
