require 'parser/current'

module RailsERD
  class Domain
    class RubyParser
      class << self
        def parse_source(source, filename = '(string)')
          buffer = Parser::Source::Buffer.new(filename)
          buffer.source = source

          ast = Parser::CurrentRuby.new.parse(buffer)
          return nil if ast.nil?

          extract_class_info(ast)
        rescue Parser::SyntaxError => e
          warn "Syntax error in #{filename}: #{e.message}"
          nil
        end

        def parse_file(file_path)
          source = File.read(file_path)
          parse_source(source, file_path)
        end

        private

        def extract_class_info(ast)
          result = {
            class_name: nil,
            superclass: nil,
            public_methods: [],
            namespace: []
          }

          process_node(ast, result, :public, [])

          result[:class_name] = ([*result[:namespace], result[:class_name]].compact.join('::')) if result[:class_name]
          result
        end

        def process_node(node, result, visibility, namespace)
          return unless node.is_a?(Parser::AST::Node)

          case node.type
          when :class
            class_name_node, superclass_node, body = node.children
            result[:class_name] = const_name(class_name_node)
            result[:superclass] = const_name(superclass_node) if superclass_node
            result[:namespace] = namespace.dup

            process_node(body, result, :public, namespace) if body

          when :module
            module_name_node, body = node.children
            new_namespace = namespace + [const_name(module_name_node)]
            process_node(body, result, visibility, new_namespace) if body

          when :def, :defs
            if node.type == :defs
              # Class method (self.method_name)
              _self, method_name, args = node.children
            else
              # Instance method
              method_name, args = node.children
            end

            if visibility == :public
              signature = build_signature(method_name, args)
              result[:public_methods] << {
                name: method_name,
                signature: signature,
                class_method: node.type == :defs
              }
            end

          when :begin
            # Process multiple statements, tracking visibility changes
            current_visibility = visibility
            node.children.each do |child|
              if child.is_a?(Parser::AST::Node) && child.type == :send
                receiver, method_name, *_args = child.children
                if receiver.nil? && [:private, :protected, :public].include?(method_name)
                  current_visibility = method_name
                  next
                end
              end
              process_node(child, result, current_visibility, namespace)
            end
          end

          # Process children for other node types
          unless [:def, :defs, :class, :module, :begin].include?(node.type)
            node.children.each { |child| process_node(child, result, visibility, namespace) }
          end
        end

        def const_name(node)
          return nil unless node

          case node.type
          when :const
            node.children.last.to_s
          when :send
            # Handle :: notation like A::B
            parts = []
            current = node
            while current && current.type == :send
              parts.unshift(current.children[1].to_s)
              current = current.children[0]
            end
            parts.unshift(const_name(current)) if current
            parts.join('::')
          else
            nil
          end
        end

        def build_signature(method_name, args_node)
          return method_name.to_s unless args_node

          params = []
          args_node.children.each do |arg|
            case arg.type
            when :arg
              params << arg.children.first.to_s
            when :optarg
              name = arg.children.first
              params << "#{name} = ..."
            when :restarg
              params << "*#{arg.children.first}"
            when :kwarg
              params << "#{arg.children.first}:"
            when :kwoptarg
              name = arg.children.first
              params << "#{name}: ..."
            when :blockarg
              params << "&#{arg.children.first}"
            end
          end

          "#{method_name}(#{params.join(', ')})"
        end
      end
    end
  end
end
