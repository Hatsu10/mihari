# frozen_string_literal: true

module Mihari
  module Analyzers
    ANALYZER_TO_CLASS = {
      "binaryedge" => BinaryEdge,
      "censys" => Censys,
      "circl" => CIRCL,
      "crtsh" => Crtsh,
      "dnpedia" => DNPedia,
      "dnstwister" => DNSTwister,
      "feed" => Feed,
      "greynoise" => GreyNoise,
      "onyphe" => Onyphe,
      "otx" => OTX,
      "passivetotal" => PassiveTotal,
      "pt" => PassiveTotal,
      "pulsedive" => Pulsedive,
      "securitytrails" => SecurityTrails,
      "shodan" => Shodan,
      "spyse" => Spyse,
      "st" => SecurityTrails,
      "urlscan" => Urlscan,
      "virustotal_intelligence" => VirusTotalIntelligence,
      "virustotal" => VirusTotal,
      "vt_intel" => VirusTotalIntelligence,
      "vt" => VirusTotal,
      "zoomeye" => ZoomEye
    }.freeze

    EMITTER_TO_CLASS = {
      "database" => Emitters::Database,
      "http" => Emitters::HTTP,
      "misp" => Emitters::MISP,
      "slack" => Emitters::Slack,
      "the_hive" => Emitters::TheHive,
      "webhook" => Emitters::Webhook
    }.freeze

    class Rule < Base
      include Mixins::DisallowedDataValue

      option :title
      option :description
      option :queries

      option :id, default: proc { "" }
      option :tags, default: proc { [] }
      option :allowed_data_types, default: proc { ALLOWED_DATA_TYPES }
      option :disallowed_data_values, default: proc { [] }

      option :emitters, optional: true
      option :enrichers, optional: true

      attr_reader :source

      def initialize(**kwargs)
        super(**kwargs)

        @source = id

        @emitters = emitters || DEFAULT_EMITTERS
        @enrichers = enrichers || DEFAULT_ENRICHERS

        validate_analyzer_configurations
      end

      #
      # Returns a list of artifacts matched with queries
      #
      # @return [Array<Mihari::Artifact>]
      #
      def artifacts
        artifacts = []

        queries.each do |original_params|
          parmas = original_params.deep_dup

          analyzer_name = parmas[:analyzer]
          klass = get_analyzer_class(analyzer_name)

          query = parmas[:query]

          # set interval in the top level
          options = parmas[:options] || {}
          interval = options[:interval]
          parmas[:interval] = interval if interval

          analyzer = klass.new(query, **parmas)

          # Use #normalized_artifacts method to get atrifacts as Array<Mihari::Artifact>
          # So Mihari::Artifact object has "source" attribute (e.g. "Shodan")
          artifacts << analyzer.normalized_artifacts
        end

        artifacts.flatten
      end

      #
      # Normalize artifacts
      # - Uniquefy artifacts by #uniq(&:data)
      # - Reject an invalid artifact (for just in case)
      # - Select artifacts with allowed data types
      # - Reject artifacts with disallowed data values
      #
      # @return [Array<Mihari::Artifact>]
      #
      def normalized_artifacts
        @normalized_artifacts ||= artifacts.uniq(&:data).select(&:valid?).select do |artifact|
          allowed_data_types.include? artifact.data_type
        end.reject do |artifact|
          disallowed_data_value? artifact.data
        end
      end

      #
      # Enriched artifacts
      #
      # @return [Array<Mihari::Artifact>]
      #
      def enriched_artifacts
        @enriched_artifacts ||= Parallel.map(unique_artifacts) do |artifact|
          enrichers.each do |enricher|
            artifact.enrich_by_enricher(enricher[:enricher])
          end

          artifact
        end
      end

      #
      # Normalized disallowed data values
      #
      # @return [Array<Regexp, String>]
      #
      def normalized_disallowed_data_values
        @normalized_disallowed_data_values ||= disallowed_data_values.map { |v| normalize_disallowed_data_value v }
      end

      #
      # Check whether a value is a disallowed data value or not
      #
      # @return [Boolean]
      #
      def disallowed_data_value?(value)
        return true if normalized_disallowed_data_values.include?(value)

        normalized_disallowed_data_values.select do |disallowed_data_value|
          disallowed_data_value.is_a?(Regexp)
        end.any? do |disallowed_data_value|
          disallowed_data_value.match?(value)
        end
      end

      private

      #
      # Get emitter class
      #
      # @param [String] emitter_name
      #
      # @return [Class<Mihari::Emitters::Base>] emitter class
      #
      def get_emitter_class(emitter_name)
        emitter = EMITTER_TO_CLASS[emitter_name]
        return emitter if emitter

        raise ArgumentError, "#{emitter_name} is not supported"
      end

      def valid_emitters
        @valid_emitters ||= emitters.filter_map do |original_params|
          params = original_params.deep_dup

          name = params[:emitter]
          params.delete(:emitter)

          klass = get_emitter_class(name)
          emitter = klass.new(**params)

          emitter.valid? ? emitter : nil
        end
      end

      #
      # Get analyzer class
      #
      # @param [String] analyzer_name
      #
      # @return [Class<Mihari::Analyzers::Base>] analyzer class
      #
      def get_analyzer_class(analyzer_name)
        analyzer = ANALYZER_TO_CLASS[analyzer_name]
        return analyzer if analyzer

        raise ArgumentError, "#{analyzer_name} is not supported"
      end

      #
      # Validate configuration of analyzers
      #
      def validate_analyzer_configurations
        queries.each do |params|
          analyzer_name = params[:analyzer]
          klass = get_analyzer_class(analyzer_name)

          instance = klass.new("dummy")
          unless instance.configured?
            klass_name = klass.to_s.split("::").last
            raise ConfigurationError, "#{klass_name} is not configured correctly"
          end
        end
      end
    end
  end
end
