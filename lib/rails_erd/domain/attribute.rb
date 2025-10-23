# encoding: utf-8

module RailsERD
  class Domain
    # Describes an entity's attribute. Attributes represent public methods
    # in a Ruby class.
    class Attribute
      extend Inspectable
      inspection_attributes :name

      attr_reader :entity, :method_data

      def initialize(entity, method_data) # @private :nodoc:
        @entity = entity
        @method_data = method_data
      end

      # The name of the attribute (method signature).
      def name
        method_data[:signature]
      end

      # Returns +true+ if this is a class method.
      def class_method?
        method_data[:class_method] || false
      end

      # For compatibility with diagram generators
      def content?
        true
      end

      # For compatibility with diagram generators
      def primary_key?
        false
      end

      # For compatibility with diagram generators
      def foreign_key?
        false
      end

      # For compatibility with diagram generators
      def timestamp?
        false
      end

      # For compatibility with diagram generators
      def inheritance?
        false
      end

      # For compatibility with diagram generators
      def false?
        false
      end

      def ==(other) # @private :nodoc:
        other.is_a?(Attribute) && other.name == name && other.entity == entity
      end

      def <=>(other) # @private :nodoc:
        name <=> other.name
      end

      def to_s # @private :nodoc:
        prefix = class_method? ? '+ ' : '- '
        "#{prefix}#{name}"
      end

      # For compatibility with diagram generators
      def type_description
        name
      end
    end
  end
end
