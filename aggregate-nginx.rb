#!/usr/bin/env ruby

#
# Load required gems
#
begin
    require 'rubygems'
    require 'bundler/setup'
    require 'erb'
    require 'json'
    require 'ostruct'
    require 'optparse'
    require 'text-table'
    require 'yaml'
    require 'chronic'
rescue => e
    STDERR.puts("Failed to load required gem(s): #{e.message}")
end

VERSION=0.1

################################################################################
# Below I've defined regex for matching single nginx variable in log_format
# statement (so we can substitute them into named captures which have names
# equal to  variable name). That's LOG_VAR_REPLACEMENT job - it transforms
# variable name into named capture. e.g:
# log_format '$remote_addr $uri' will be conveniently transformed into:
# '(?<remote_addr>.*) (?<uri>.*)'
################################################################################
LOG_VAR_REGEX=/\\\$([a-z_-]+)/
LOG_VAR_REPLACEMENT='(?<\1>.*)'

################################################################################
# HTTP Errors are in range 400-599
################################################################################
HTTP_ERROR_RANGE=(400...600) # [400,599)

# Default configuration name
DEFAULT_CFG_NAME='default'

# Default configuration file (will be used if none passed on commandline)
DEFAULT_CFG_FILE='config.yml'

# Regular expression for splitting $time_local variable
TIME_LOCAL_REGEX=/([0-9]{2})\/([a-zA-Z]+)\/([0-9]{4}):([0-9]{2}):([0-9]{2}):([0-9]{2}) ([+-])([0-9]{2})([0-9]{2})/

# Month names which are set in $time_local
TIME_LOCAL_MONTHS = {
    'Jan' => 1,
    'Feb' => 2,
    'Mar' => 3,
    'Apr' => 4,
    'May' => 5,
    'Jun' => 6,
    'Jul' => 7,
    'Aug' => 8,
    'Sep' => 9,
    'Oct' => 10,
    'Nov' => 11,
    'Dev' => 12
}

# Default template file
DEFAULT_TEMPLATE_FILE='email.erb'

class NginxAccessLogAggregator

    def initialize


        # Process command-line options
        parse_opts

        unless options_valid(@options)
            error("Passed options are invalid!")
            help
            exit 1
        end

        # Load configuration
        @config = load_config(@options[:file])

        unless config_valid(@config)
            error("Config invalid!")
            exit 1
        end

        unless @config [@options[:config]]
            error "No configuration named #{@options[:config]} in #{@options[:file]}, available configurations are:\n#{@config.keys.join("\n")}"
            exit 1
        end

        unless @config[DEFAULT_CFG_NAME].nil?
            @data = @config[DEFAULT_CFG_NAME].merge(@config[@options[:config]])
        else
            @data = @config[@options[:config]]
        end

        unless configuration_valid(@data)
            error("Configuration #{@options[:config]} invalid!")
            exit 1
        end

        parse_dates

        begin
            @email_tpl = File.read(@data['template'])
        rescue => e
            error "Failed to load output template: #{e}"
            exit 1
        end

        matches = gather_matches(@data['source'])

        aggregate_results(matches)

        puts render_text(@data,@email_tpl)
    end


    def help
        puts "Nginx log aggregator v.#{VERSION}"
        puts "How to use:"
        puts "#{$0} -c configuration_name -f yaml_config_file.yml"
        puts 
    end

    # 
    # Tries to parse dates stored in configuration in natural format and
    # convert them to something more useful - Time instances
    # so we can compare them and such
    def parse_dates
        # Try to parse dates from selected configuration (if any)
        begin
            unless @data['time_local']['from'].nil?
                @data['time_local']['from'] = Chronic.parse(@data['time_local']['from'])
            end

            unless @data['time_local']['to'].nil?
                @data['time_local']['to'] = Chronic.parse(@data['time_local']['to'])
            end
        rescue => e
            error "Failed to process from/to dates set in configuration, check syntax etc. (exception was: #{e})"
            exit 1
        end
    end


    #
    # Filters out too old and too new entries
    # from matches array (if restrictions are set)
    def filter_dates!(matches)
        if @data['time_local']['from'].class == Time
            matches.select! do |item|
                # dont remove matches without date
                true unless item['time_local']
                time_local_parse(item['time_local']) >= @data['time_local']['from']
            end

        end

        if @data['time_local']['to'].class == Time
            matches.select! do |item|
                # dont remove matches without date
                true unless item['time_local']
                time_local_parse(item['time_local']) <= @data['time_local']['to']
            end

        end
    end


    # Parses string which should be in format
    # DD/Mon/YYYY:HH:MM:SS +HHMM
    # (it's used in $time_local variable in nginx log)
    def time_local_parse(str)
        match = TIME_LOCAL_REGEX.match(str)

        if match.nil? || match.captures.count != 9
            error "time: #{str} is not valid nginx $time_local string"
        end

        captures = match.captures

       # Example capture array looks like this:
       # ["25", "Jun", "2014", "06", "26", "42", "+", "02", "00"]

        day = captures[0].to_i
        month = TIME_LOCAL_MONTHS[captures[1] % TIME_LOCAL_MONTHS.length]
        year = captures[2].to_i
        hour = captures[3].to_i
        minute = captures[4].to_i
        second = captures[5].to_i
        offset = ((captures[6]  == '+' ? 1 : -1) * captures[7].to_i)

        return Time.local(second,minute,hour,day,month,year,nil,nil,false,offset)
    end

    # Processes command-line options
    def parse_opts

        @options = {
            :verbose => false,
            :config  => DEFAULT_CFG_NAME,
            :file  => DEFAULT_CFG_FILE,
            :template => DEFAULT_TEMPLATE_FILE
        }

        begin
            OptionParser.new do |p|
                p.on("-c","--configuration CONFIG" ) {|c| @options[:config] = c }
                p.on("-f","--file CONFIG" ) {|f| @options[:file] = f }
                p.on("-v","--verbose" ) { @options[:verbose] = true }
                p.on("-h","--help" ) { help; exit 0}
            end.parse!
        rescue => e
            error "exception ocurred during command line options parsing: #{e}"
            return false
        end

        return true
    end

    # checks processed options validity
    def options_valid(opts)
        unless opts.kind_of?(Hash)
            error "options object should be Hash instance, passed #{opts.class}"
            return false
        end

        if opts[:config].nil?
            error "no  configuration path passed (-f, --config)"
            return false
        end

        return true
    end

    # Checks whether loaded YML configuration  has
    # correct structure
    def configuration_valid(config)
        ok = true

        unless config.class == Hash
            error "selected configuration is not a hash"
            ok = false
        end

        if config['format'].nil?
            error "selected configuration doesn't contain log format"
            ok = false
        end

        if config['template'].nil?
            error "selected configuration doesn't contain email template path"
            ok = false
        end

        return ok
    end

    # Prints error message
    def error(msg)
        STDERR.puts("ERROR: #{msg}")
    end


    # Tries to load YAML configuration from passed path
    # returns nil or configuration object
    def load_config(path)
        yml = nil
        begin
            yml = YAML.load_file(path)

        rescue => e
            STDERR.puts("Exception occured when trying to load file: #{path} : #{e.message}")
            yml = nil
        end

        return yml
    end


    def config_valid(config)
        if config.nil?
            return false
        end

        if config[DEFAULT_CFG_NAME].nil?
            error "No default configuration '#{DEFAULT_CFG_NAME}' found in loaded config file!"
            return false
        end

        return true
    end

    # Splits source file(s) into
    # array containing each entry as hash
    # in format:
    # {
    #    $var_name => $var_value
    # }
    #
    # where each key is nginx variable name from log_format directive
    # and value is value for this variable in matched line
    #
    # example hash may look like this:
    # {
    #  request => 'GET /',
    #  remote_addr => '1.2.3.4'
    #  [...]
    # }
    #
    def gather_matches(source)
        re =  Regexp.new(Regexp.escape(@data['format']).gsub(LOG_VAR_REGEX,LOG_VAR_REPLACEMENT),'g')
        matches = []

        if source.class == String
            matches = scan_file(re,source)
        end

        if source.class == Array
            source.each do |file|
                matches += scan_file(re,file)
            end
        end

       return matches
    end


    #
    # Scans one file for lines matching pattern stored in regex 're'
    # and returns array of hashes consisting named captures from re
    # for each matched line
    #
    # e.g
    #
    # [
    #   {
    #       remote_addr => '127.0.0.1',
    #       request => 'GET /'
    #   },
    #   {
    #       remote_addr => '127.0.0.2',
    #       request => 'POST /test'
    #   },
    # ]
    #
    #
    #
    def scan_file(re,file)
        matches = []
        capture_indices = re.named_captures
        begin
            File.read(file).scan(re) do |match|
                temp = {}
                capture_indices.each_pair do |name,ind|
                    temp[name] = match[ind[0] - 1]
                end

                if HTTP_ERROR_RANGE.include?(temp['status'].to_i)
                    matches << temp
                end
            end
        rescue => e
            error "Failed to scan file #{file} ! : #{e}"
        end
        return matches
    end


    #
    # Performs aggregation tasks on array containing all problems
    #
    def aggregate_results(result_arr)
        filter_dates!(result_arr)
        @data['problematic_entries'] =  result_arr
        @data['top_problems'] =  top_problems(result_arr,@data['limits']['top_problems'])
    end


    #
    # Returns up array consisting of up to 'limit'
    # entries in format
    # [
    #    uri,
    #    total_problems,
    #    "HTTP/XXX:WWW,HTTP/YYY:ZZZ'
    # ]
    #
    # last array element contains string summarizing HTTP response codes for requests
    # for this URI. This allows to show problems which caused different problems 
    # because we are interested about problems and not only particular type of error.
    #
    def top_problems(array,limit)
        out = []

        return out unless array.class == Array

        array.group_by { |h| h['request'] }.sort_by { |k,v| - v.size }.take_while do |arr|
            uri = arr[0]
            details = arr[1]
            counted_codes = count_codes(details)
            counted_codes_str = counted_codes_to_str(counted_codes)
            threshold = @data['limits']['min_count']

            if threshold.nil? || details.size >= threshold
                out <<  [
                     uri,
                     details.count,
                     counted_codes_str
                ]
            end

            # stop processing when limit is reached, or allow unlimited output when limit is nil
            limit.nil? || out.size < limit  - 1
        end

        return out
    end

    # counts how many occurences of each http code was found in details hash
    def count_codes(details)
        counts = {}
        details.group_by {|x| x['status'].to_i}.each {|k,v| counts[k] = v.count}
        return counts.sort
    end

    # Generates nice string from hash containing HTTP codes as keys
    # and occurence count as values
    def counted_codes_to_str(hash)
        str =''
        hash.each { |k,v| str += 'HTTP/%s:%s, ' % [k,v] }
        return str[0,str.length - 2]
    end

    # Sorts array by hash key
    def sort_by_hashkey(array,key)
        array.sort_by {|hash| hash[key] }
    end

    #  Renders text from template
    #  Contents of data_hash are bound to ERB instance
    #  so they are available for use in template
    def render_text(data_hash,template)
        namespace = OpenStruct.new(data_hash);
        return ERB.new(template,0,'>').result(namespace.instance_eval {binding})
    end
end

NginxAccessLogAggregator.new
