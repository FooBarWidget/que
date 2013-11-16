require 'json'

module Que
  class Job
    class << self
      def queue(*args)
        if args.last.is_a?(Hash)
          options  = args.pop
          run_at   = options.delete(:run_at)
          priority = options.delete(:priority)
          args << options if options.any?
        end

        attrs = {
          :type => to_s,
          :args => JSON.dump(args)
        }

        if t = run_at || @default_run_at && @default_run_at.call
          attrs[:run_at] = t
        end

        if p = priority || @default_priority
          attrs[:priority] = p
        end

        Que.execute *insert_sql(attrs)
      end

      # Job.work should return truthy if it worked a job, or needs to indicate
      # that there may be work available. In a work loop, we'd want to sleep
      # for a while only if Job.work returned falsy.
      def work
        # Since we're taking session-level advisory locks, we have to hold the
        # same connection throughout the process of getting a job, working it,
        # deleting it, and removing the lock.
        Que.connection.checkout do
          begin
            if row = Que.execute(:lock_job).first
              # Edge case: It's possible for the lock statement to have grabbed a
              # job that's already been worked, if the statement took its MVCC
              # snapshot while the job was processing (making it appear to still
              # exist), but didn't actually attempt to lock it until the job was
              # finished (making it appear to be unlocked). Now that we have the
              # job lock, we know that a previous worker would have deleted it by
              # now, so we just check that it still exists before working it. Note
              # that there is currently no spec for this behavior, since I'm not
              # sure how to deterministically commit a transaction that deletes a
              # job between these two queries.
              check = Que.execute(:check_job, [row['priority'], row['run_at'], row['job_id']])
              return true if check.none?

              job = const_get(row['type']).new(row)

              start = Time.now
              job._run
              time = Time.now - start
              Que.log :info, "Worked job in #{(time * 1000).round(1)} ms: #{job.inspect}"

              job
            end
          rescue => error
            if row
              count   = row['error_count'].to_i + 1
              run_at  = Time.now + (count ** 4 + 3)
              message = "#{error.message}\n#{error.backtrace.join("\n")}"
              Que.execute :set_error, [count, run_at, message, row['priority'], row['run_at'], row['job_id']]
            end

            if Que.error_handler
              Que.error_handler.call(error) rescue nil
            end
            return true
          ensure
            Que.execute "SELECT pg_advisory_unlock($1)", [row['job_id']] if row
          end
        end
      end

      private

      # Column names are not escaped, so this method should not be called with untrusted hashes.
      def insert_sql(hash)
        number       = 0
        columns      = []
        placeholders = []
        values       = []

        hash.each do |key, value|
          columns      << key
          placeholders << "$#{number += 1}"
          values       << value
        end

        ["INSERT INTO que_jobs (#{columns.join(', ')}) VALUES (#{placeholders.join(', ')});", values]
      end
    end

    def initialize(attrs)
      @attrs = attrs
    end

    def _run
      run *_indifferentiate(JSON.load(@attrs['args']))
      destroy unless @destroyed
    end

    # A job without a run method defined doesn't do anything. This is useful in testing.
    def run(*args)
    end

    private

    def destroy
      @destroyed = true
      Que.execute :destroy_job, [@attrs['priority'], @attrs['run_at'], @attrs['job_id']]
    end

    def _indifferentiate(input)
      case input
      when Hash
        h = _indifferent_hash
        input.each { |k, v| h[k] = _indifferentiate(v) }
        h
      when Array
        input.map { |v| _indifferentiate(v) }
      else
        input
      end
    end

    def _indifferent_hash
      # Tiny hack to better support Rails.
      if {}.respond_to?(:with_indifferent_access)
        {}.with_indifferent_access
      else
        Hash.new { |hash, key| hash[key.to_s] if Symbol === key }
      end
    end
  end
end
