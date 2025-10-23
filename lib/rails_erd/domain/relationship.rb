require "rails_erd/domain/relationship/cardinality"

module RailsERD
  class Domain
    # Describes a relationship between two entities. In class diagrams,
    # relationships represent method calls between classes.
    class Relationship
      class << self
        def from_method_call(domain, source, destination)
          new(domain, source, destination)
        end
      end

      extend Inspectable
      inspection_attributes :source, :destination

      # The domain in which this relationship is defined.
      attr_reader :domain

      # The source entity (the class making the call).
      attr_reader :source

      # The destination entity (the class being called).
      attr_reader :destination

      def initialize(domain, source, destination) # @private :nodoc:
        @domain = domain
        @source = source
        @destination = destination
      end

      # For class diagrams, relationships are always direct.
      def indirect?
        false
      end

      # Cardinality is not applicable for method calls, but kept for compatibility.
      def cardinality
        Cardinality.new(Cardinality::N, Cardinality::N)
      end

      # For compatibility with diagram generators
      def one_to_one?
        false
      end

      # For compatibility with diagram generators
      def one_to_many?
        false
      end

      # For compatibility with diagram generators
      def many_to_many?
        true  # Default to many-to-many for method calls
      end

      # For compatibility with diagram generators
      def to_many?
        true
      end

      # For compatibility with diagram generators
      def many_to?
        true
      end

      # For compatibility with diagram generators
      def source_optional?
        true
      end

      # For compatibility with diagram generators
      def destination_optional?
        true
      end

      # For compatibility with diagram generators
      def strength
        1.0
      end

      def ==(other) # @private :nodoc:
        other.is_a?(Relationship) &&
          other.source == source &&
          other.destination == destination
      end

      def to_s # @private :nodoc:
        "#{source} -> #{destination}"
      end
    end
  end
end
