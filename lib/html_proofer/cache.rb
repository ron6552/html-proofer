# frozen_string_literal: true

require 'date'
require 'json'
require 'uri'

module HTMLProofer
  class Cache
    include HTMLProofer::Utils

    CACHE_VERSION = 2

    DEFAULT_STORAGE_DIR = File.join('tmp', '.htmlproofer')
    DEFAULT_CACHE_FILE_NAME = 'cache.log'
    DEFAULT_STRUCTURE = {
      version: CACHE_VERSION,
      internal: {},
      external: {}
    }.freeze

    URI_REGEXP = URI::DEFAULT_PARSER.make_regexp

    attr_reader :exists, :cache_log, :storage_dir, :cache_file

    def initialize(runner, options)
      @runner = runner
      @logger = @runner.logger

      @cache_datetime = DateTime.now
      @cache_time = @cache_datetime.to_time

      if blank?(options)
        define_singleton_method(:enabled?) { false }
      else
        define_singleton_method(:enabled?) { true }
        setup_cache!(options)
        @parsed_timeframe = parsed_timeframe(options[:timeframe])
      end
    end

    def within_timeframe?(time)
      return false if time.nil?

      time = Time.parse(time) if time.is_a?(String)
      (@parsed_timeframe..@cache_time).cover?(time)
    end

    def parsed_timeframe(timeframe)
      time, date = timeframe.match(/(\d+)(\D)/).captures
      time = time.to_i
      case date
      when 'M'
        time_ago(time, :months)
      when 'w'
        time_ago(time, :weeks)
      when 'd'
        time_ago(time, :days)
      when 'h'
        time_ago(time, :hours)
      else
        raise ArgumentError, "#{date} is not a valid timeframe!"
      end
    end

    def add_internal(url, metadata, found)
      return unless enabled?

      @cache_log[:internal][url] = { time: @cache_time, metadata: [] } if @cache_log[:internal][url].nil?

      @cache_log[:internal][url][:metadata] << construct_internal_link_metadata(metadata, found: found)
    end

    def add_external(url, filenames, status, msg)
      return unless enabled?

      @cache_log[:external][url] = { time: @cache_time, status: status, message: msg, metadata: [] } if @cache_log[:external][url].nil?

      @cache_log[:external][url][:metadata] = filenames
    end

    def construct_internal_link_metadata(metadata, found: nil)
      m = {
        source: metadata[:source],
        current_path: metadata[:current_path],
        line: metadata[:line],
        base_url: metadata[:base_url]
      }

      m[:found] = found unless found.nil?

      m
    end

    def detect_url_changes(found_urls, type)
      # if there were no urls, bail
      return {} if found_urls.empty?

      additions = determine_additions(found_urls, type)

      determine_deletions(found_urls, type)

      additions
    end

    # prepare to add new URLs detected
    private def determine_additions(found_urls, type)
      additions = found_urls.reject do |url, _|
        # url = unescape_url(url)
        if @cache_log[type].include?(url)
          true
        else
          @logger.log :debug, "Adding #{url} to cache check"
          false
        end
      end

      new_link_count = additions.length
      new_link_text = pluralize(new_link_count, "#{type} link", "#{type} links")
      @logger.log :info, "Adding #{new_link_text} to the cache..."

      additions
    end

    # remove from cache URLs that no longer exist
    private def determine_deletions(found_urls, type)
      deletions = 0

      @cache_log[type].delete_if do |url, _|
        url = unescape_url(url)

        if found_urls.include?(url)
          false
        elsif url_matches_type?(url, type)
          @logger.log :debug, "Removing #{url} from cache check"
          deletions += 1
          true
        end
      end

      del_link_text = pluralize(deletions, "#{type} link", "#{type} links")
      @logger.log :info, "Removing #{del_link_text} from the cache..."
    end

    def write
      return unless enabled?

      File.write(@cache_file, @cache_log.to_json)
    end

    def retrieve_urls(urls, type)
      return urls if empty?

      urls_to_check = detect_url_changes(urls, type)

      @cache_log[type].each_pair do |url, cache|
        next if within_timeframe?(cache[:time])

        urls_to_check[url] = cache[:metadata] # recheck expired links
      end

      urls_to_check
    end

    # FIXME: it seems that Typhoeus actually acts on escaped URLs,
    # but there's no way to get at that information, and the cache
    # stores unescaped URLs. Because of this, some links, such as
    # github.com/search/issues?q=is:open+is:issue+fig are not matched
    # as github.com/search/issues?q=is%3Aopen+is%3Aissue+fig
    def unescape_url(url)
      Addressable::URI.unescape(url)
    end

    def empty?
      blank?(@cache_log) || (@cache_log[:internal].empty? && @cache_log[:external].empty?)
    end

    private def setup_cache!(options)
      @storage_dir = options[:storage_dir] || DEFAULT_STORAGE_DIR

      FileUtils.mkdir_p(storage_dir) unless Dir.exist?(storage_dir)

      cache_file_name = options[:cache_file] || DEFAULT_CACHE_FILE_NAME

      @cache_file = File.join(storage_dir, cache_file_name)

      return (@cache_log = DEFAULT_STRUCTURE) unless File.exist?(@cache_file)

      contents = File.read(@cache_file)

      return (@cache_log = DEFAULT_STRUCTURE) if blank?(contents)

      log = JSON.parse(contents, symbolize_names: true)

      old_cache = (cache_version = log[:version]).nil?
      @cache_log = if old_cache # previous cache version, create a new one
                     DEFAULT_STRUCTURE
                   elsif cache_version != CACHE_VERSION
                   # if cache version is newer...do something
                   else
                     log[:internal] = log[:internal].transform_keys(&:to_s)
                     log[:external] = log[:external].transform_keys(&:to_s)
                     log
                   end
    end

    private def time_ago(measurement, unit)
      case unit
      when :months
        @cache_datetime >> -measurement
      when :weeks
        @cache_datetime - (measurement * 7)
      when :days
        @cache_datetime - measurement
      when :hours
        @cache_datetime - Rational(measurement / 24.0)
      end.to_time
    end

    private def url_matches_type?(url, type)
      return true if type == :internal && url !~ URI_REGEXP
      return true if type == :external && url =~ URI_REGEXP
    end
  end
end