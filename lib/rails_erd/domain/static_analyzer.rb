require 'parser/current'

module RailsERD
  class Domain
    class StaticAnalyzer
      class << self
        def find_method_calls(source)
          buffer = Parser::Source::Buffer.new('(string)')
          buffer.source = source

          ast = Parser::CurrentRuby.new.parse(buffer)
          return [] if ast.nil?

          calls = []
          extract_calls(ast, calls, nil)
          calls
        rescue Parser::SyntaxError
          []
        end

        private

        def extract_calls(node, calls, current_method)
          return unless node.is_a?(Parser::AST::Node)

          # Track when we enter a method definition
          if node.type == :def
            method_name = node.children[0]
            # Process the method body with the current method context
            method_body = node.children[2]
            extract_calls(method_body, calls, method_name) if method_body
            return
          elsif node.type == :defs
            # Class method (self.method_name)
            method_name = node.children[1]
            method_body = node.children[3]
            extract_calls(method_body, calls, method_name) if method_body
            return
          end

          if node.type == :send
            receiver, method_name, *_args = node.children

            # Only track calls on constants (ClassName.method)
            if constant_node?(receiver)
              calls << {
                source_method: current_method,
                target_class: const_name(receiver),
                target_method: method_name
              }
            end
          end

          # Recursively process children
          node.children.each { |child| extract_calls(child, calls, current_method) }
        end

        def constant_node?(node)
          return false unless node.is_a?(Parser::AST::Node)
          [:const, :send].include?(node.type) && const_name(node)
        end

        def const_name(node)
          return nil unless node

          case node.type
          when :const
            # Check if it's a fully qualified constant
            namespace, name = node.children
            if namespace
              "#{const_name(namespace)}::#{name}"
            else
              name.to_s
            end
          when :send
            # Handle :: notation like A::B::C
            receiver, method_name = node.children
            if method_name == :const
              const_name(receiver)
            elsif receiver && constant_node?(receiver)
              # This is Namespace::Class pattern
              parts = []
              current = node
              while current && current.type == :send
                parts.unshift(current.children[1].to_s)
                current = current.children[0]
              end
              if current && current.type == :const
                parts.unshift(const_name(current))
              end
              parts.join('::')
            else
              nil
            end
          else
            nil
          end
        end
      end
    end
  end
end
