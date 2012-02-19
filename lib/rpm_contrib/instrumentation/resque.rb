require 'rpm_contrib/language_support'

# call this now so it is memoized before potentially forking worker processes
RPMContrib::LanguageSupport.can_fork?

module Resque
  module Plugins
    module NewRelicInstrumentation
      include NewRelic::Agent::Instrumentation::ControllerInstrumentation
      
      def around_perform_with_monitoring(*args)
        begin
          trace_options = if self.name == 'Backgrounded::Handler::ResqueHandler'
            {
              :class_name => args[0],
              :name => args[2].to_s,
              :params => @payload,
              :category => 'OtherTransaction/BackgroundedResqueJob'
            }
          else
            {
              :class_name => self.name,
              :name => 'perform',
              :category => 'OtherTransaction/ResqueJob'
            }
          end
          perform_action_with_newrelic_trace(trace_options) do
            yield(*args)
          end
        ensure
          NewRelic::Agent.save_data if NewRelic::Agent.agent.started?
        end
      end
    end
  end
end

module RPMContrib
  module Instrumentation
    module ResqueInstrumentationInstaller
      def payload_class
        klass = super
        klass.instance_eval do
          extend ::Resque::Plugins::NewRelicInstrumentation
        end
      end
    end
  end
end

DependencyDetection.defer do
  @name = :resque
  
  depends_on do
    defined?(::Resque::Job) and not NewRelic::Control.instance['disable_resque']
  end

  executes do
    NewRelic::Agent.logger.debug 'Installing Resque instrumentation'
  end
  
  executes do
    # == Resque Instrumentation
    #
    # Installs a hook to ensure the agent starts manually when the worker
    # starts and also adds the tracer to the process method which executes
    # in the forked task.
    ::Resque::Job.class_eval do
      def self.new(*args)
        super(*args).extend RPMContrib::Instrumentation::ResqueInstrumentationInstaller
      end
    end

    ::Resque.before_first_fork do
      NewRelic::Agent.manual_start(:dispatcher => :resque,
                                   :sync_startup => true)
      NewRelic::Agent.after_fork(:force_reconnect => true)
    end

  end
end 
