# Class Diagram Transformation Implementation Plan

> **For Claude:** Use `${SUPERPOWERS_SKILLS_ROOT}/skills/collaboration/executing-plans/SKILL.md` to implement this plan task-by-task.

**Goal:** Transform rails-erd from an ERD generator (database tables/columns) to a class diagram generator (Ruby classes/methods with method call relationships).

**Architecture:** Keep existing three-layer architecture (Domain → Diagram → CLI) but replace Domain loading logic. Instead of reflecting on ActiveRecord models, parse Ruby files from app/ and lib/ directories. Maintain Entity/Attribute/Relationship abstractions but repurpose them (Entity=Class, Attribute=Method, Relationship=MethodCall). Diagram generators require minimal changes.

**Tech Stack:** Ruby, parser gem (AST parsing), existing Graphviz/Mermaid diagram generators, Minitest

---

## Task 1: Add parser gem dependency

**Files:**
- Modify: `rails-erd.gemspec`

**Step 1: Add parser gem to gemspec**

In `rails-erd.gemspec`, add to dependencies:

```ruby
spec.add_dependency 'parser', '~> 3.0'
```

**Step 2: Install dependencies**

Run: `bundle install`
Expected: parser gem installed successfully

**Step 3: Commit**

```bash
git add rails-erd.gemspec Gemfile.lock
git commit -m "Add parser gem dependency for Ruby AST parsing"
```

---

## Task 2: Create RubyParser to extract classes and methods

**Files:**
- Create: `lib/rails_erd/domain/ruby_parser.rb`
- Create: `test/unit/ruby_parser_test.rb`

**Step 1: Write the failing test**

Create `test/unit/ruby_parser_test.rb`:

```ruby
require File.expand_path('../../test_helper', __FILE__)

module RailsERD
  class RubyParserTest < ActiveSupport::TestCase
    def test_parses_simple_class
      source = <<~RUBY
        class UserService
          def process(user)
            user.save
          end

          def self.call
            new.process
          end

          private

          def internal_method
            nil
          end
        end
      RUBY

      result = Domain::RubyParser.parse_source(source, 'user_service.rb')

      assert_equal 'UserService', result[:class_name]
      assert_equal 2, result[:public_methods].length
      assert_includes result[:public_methods].map { |m| m[:name] }, :process
      assert_includes result[:public_methods].map { |m| m[:name] }, :call
      refute_includes result[:public_methods].map { |m| m[:name] }, :internal_method
    end

    def test_captures_method_parameters
      source = <<~RUBY
        class OrderProcessor
          def process(order, options = {})
          end
        end
      RUBY

      result = Domain::RubyParser.parse_source(source, 'order_processor.rb')
      method = result[:public_methods].first

      assert_equal :process, method[:name]
      assert_equal 'process(order, options = {})', method[:signature]
    end

    def test_captures_superclass
      source = <<~RUBY
        class AdminUser < User
        end
      RUBY

      result = Domain::RubyParser.parse_source(source, 'admin_user.rb')

      assert_equal 'User', result[:superclass]
    end

    def test_handles_namespaced_classes
      source = <<~RUBY
        module Admin
          class ReportGenerator
            def generate
            end
          end
        end
      RUBY

      result = Domain::RubyParser.parse_source(source, 'admin/report_generator.rb')

      assert_equal 'Admin::ReportGenerator', result[:class_name]
    end

    def test_returns_nil_for_syntax_errors
      source = "class Broken def end"

      result = Domain::RubyParser.parse_source(source, 'broken.rb')

      assert_nil result
    end
  end
end
```

**Step 2: Run test to verify it fails**

Run: `ruby test/unit/ruby_parser_test.rb`
Expected: FAIL with "uninitialized constant RailsERD::Domain::RubyParser"

**Step 3: Write minimal implementation**

Create `lib/rails_erd/domain/ruby_parser.rb`:

```ruby
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

          when :send
            # Check for visibility changes (private, protected, public)
            _receiver, method_name, *_args = node.children
            if [:private, :protected, :public].include?(method_name)
              visibility = method_name
            end

          when :begin
            # Process multiple statements
            node.children.each { |child| process_node(child, result, visibility, namespace) }
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
              params << "#{name} = {}"
            when :restarg
              params << "*#{arg.children.first}"
            when :kwarg
              params << "#{arg.children.first}:"
            when :kwoptarg
              name = arg.children.first
              params << "#{name}: {}"
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
```

**Step 4: Run test to verify it passes**

Run: `ruby test/unit/ruby_parser_test.rb`
Expected: All tests PASS

**Step 5: Commit**

```bash
git add lib/rails_erd/domain/ruby_parser.rb test/unit/ruby_parser_test.rb
git commit -m "Add RubyParser to extract classes and methods from Ruby source"
```

---

## Task 3: Create StaticAnalyzer to detect method calls

**Files:**
- Create: `lib/rails_erd/domain/static_analyzer.rb`
- Create: `test/unit/static_analyzer_test.rb`

**Step 1: Write the failing test**

Create `test/unit/static_analyzer_test.rb`:

```ruby
require File.expand_path('../../test_helper', __FILE__)

module RailsERD
  class StaticAnalyzerTest < ActiveSupport::TestCase
    def test_detects_constant_method_call
      source = <<~RUBY
        class OrderService
          def process
            UserMailer.send_notification
          end
        end
      RUBY

      calls = Domain::StaticAnalyzer.find_method_calls(source)

      assert_equal 1, calls.length
      assert_equal 'UserMailer', calls.first[:target_class]
      assert_equal :send_notification, calls.first[:method_name]
    end

    def test_detects_constant_new
      source = <<~RUBY
        class OrderService
          def create_user
            User.new
          end
        end
      RUBY

      calls = Domain::StaticAnalyzer.find_method_calls(source)

      assert_equal 1, calls.length
      assert_equal 'User', calls.first[:target_class]
      assert_equal :new, calls.first[:method_name]
    end

    def test_ignores_non_constant_calls
      source = <<~RUBY
        class OrderService
          def process(user)
            user.save
          end
        end
      RUBY

      calls = Domain::StaticAnalyzer.find_method_calls(source)

      assert_empty calls
    end

    def test_handles_namespaced_constants
      source = <<~RUBY
        class OrderService
          def process
            Admin::UserService.perform
          end
        end
      RUBY

      calls = Domain::StaticAnalyzer.find_method_calls(source)

      assert_equal 1, calls.length
      assert_equal 'Admin::UserService', calls.first[:target_class]
    end
  end
end
```

**Step 2: Run test to verify it fails**

Run: `ruby test/unit/static_analyzer_test.rb`
Expected: FAIL with "uninitialized constant RailsERD::Domain::StaticAnalyzer"

**Step 3: Write minimal implementation**

Create `lib/rails_erd/domain/static_analyzer.rb`:

```ruby
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
          extract_calls(ast, calls)
          calls
        rescue Parser::SyntaxError
          []
        end

        private

        def extract_calls(node, calls)
          return unless node.is_a?(Parser::AST::Node)

          if node.type == :send
            receiver, method_name, *_args = node.children

            # Only track calls on constants (ClassName.method)
            if constant_node?(receiver)
              calls << {
                target_class: const_name(receiver),
                method_name: method_name
              }
            end
          end

          # Recursively process children
          node.children.each { |child| extract_calls(child, calls) }
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
```

**Step 4: Run test to verify it passes**

Run: `ruby test/unit/static_analyzer_test.rb`
Expected: All tests PASS

**Step 5: Commit**

```bash
git add lib/rails_erd/domain/static_analyzer.rb test/unit/static_analyzer_test.rb
git commit -m "Add StaticAnalyzer to detect method calls between classes"
```

---

## Task 4: Update Domain class to scan Ruby files

**Files:**
- Modify: `lib/rails_erd/domain.rb`
- Create: `test/unit/domain_test.rb`

**Step 1: Write the failing test**

Create `test/unit/domain_test.rb`:

```ruby
require File.expand_path('../../test_helper', __FILE__)

module RailsERD
  class DomainTest < ActiveSupport::TestCase
    def setup
      @tmpdir = Dir.mktmpdir
      @app_dir = File.join(@tmpdir, 'app', 'models')
      FileUtils.mkdir_p(@app_dir)
    end

    def teardown
      FileUtils.rm_rf(@tmpdir)
    end

    def test_discovers_ruby_files_in_app_directory
      File.write(File.join(@app_dir, 'user.rb'), 'class User; end')
      File.write(File.join(@app_dir, 'order.rb'), 'class Order; end')

      files = Domain.discover_ruby_files([@tmpdir])

      assert_equal 2, files.length
      assert files.any? { |f| f.end_with?('user.rb') }
      assert files.any? { |f| f.end_with?('order.rb') }
    end

    def test_excludes_non_ruby_files
      File.write(File.join(@app_dir, 'user.rb'), 'class User; end')
      File.write(File.join(@app_dir, 'README.md'), 'Documentation')

      files = Domain.discover_ruby_files([@tmpdir])

      assert_equal 1, files.length
      assert files.first.end_with?('user.rb')
    end
  end
end
```

**Step 2: Run test to verify it fails**

Run: `ruby test/unit/domain_test.rb`
Expected: FAIL with "undefined method `discover_ruby_files'"

**Step 3: Add file discovery to Domain class**

In `lib/rails_erd/domain.rb`, add after the existing class methods:

```ruby
# Discover all Ruby files in specified directories
def self.discover_ruby_files(paths)
  paths.flat_map do |path|
    if File.directory?(path)
      Dir.glob(File.join(path, '**', '*.rb'))
    elsif File.exist?(path)
      [path]
    else
      []
    end
  end.uniq.sort
end
```

**Step 4: Run test to verify it passes**

Run: `ruby test/unit/domain_test.rb`
Expected: All tests PASS

**Step 5: Update Domain.generate to use Ruby file parsing**

In `lib/rails_erd/domain.rb`, find the `generate` method and replace its entire body with:

```ruby
def self.generate(options = {})
  # Determine which directories to scan
  root_path = options[:root] || Dir.pwd
  scan_paths = if options[:paths]
    options[:paths].map { |p| File.join(root_path, p) }
  else
    [
      File.join(root_path, 'app'),
      File.join(root_path, 'lib')
    ].select { |p| Dir.exist?(p) }
  end

  # Discover all Ruby files
  ruby_files = discover_ruby_files(scan_paths)

  # Parse each file
  parsed_classes = []
  ruby_files.each do |file_path|
    result = RubyParser.parse_file(file_path)
    if result && result[:class_name]
      result[:file_path] = file_path
      parsed_classes << result
    end
  end

  new(parsed_classes, options)
end
```

**Step 6: Update Domain#initialize to work with parsed classes**

In `lib/rails_erd/domain.rb`, replace the `initialize` method with:

```ruby
def initialize(parsed_classes, options = {})
  @options = options
  @parsed_classes = parsed_classes
  @entities = []
  @relationships = []
  @specializations = []

  process_parsed_classes
end

private

def process_parsed_classes
  # Create entities from parsed classes
  @parsed_classes.each do |parsed|
    entity = Entity.from_parsed_class(parsed, self)
    @entities << entity if entity
  end

  # Create specializations (inheritance)
  @parsed_classes.each do |parsed|
    next unless parsed[:superclass]

    source = @entities.find { |e| e.name == parsed[:class_name] }
    target = @entities.find { |e| e.name == parsed[:superclass] }

    if source && target
      @specializations << Specialization.new(self, source, target)
    end
  end

  # Create relationships (method calls)
  @parsed_classes.each do |parsed|
    source_entity = @entities.find { |e| e.name == parsed[:class_name] }
    next unless source_entity

    # Read the file and analyze method calls
    source_code = File.read(parsed[:file_path])
    calls = StaticAnalyzer.find_method_calls(source_code)

    calls.each do |call|
      target_entity = @entities.find { |e| e.name == call[:target_class] }
      next unless target_entity

      # Check if we already have this relationship
      existing = @relationships.find do |r|
        r.source == source_entity && r.destination == target_entity
      end

      unless existing
        @relationships << Relationship.from_method_call(self, source_entity, target_entity)
      end
    end
  end
end
```

**Step 7: Require the new files**

At the top of `lib/rails_erd/domain.rb`, add:

```ruby
require 'rails_erd/domain/ruby_parser'
require 'rails_erd/domain/static_analyzer'
```

**Step 8: Commit**

```bash
git add lib/rails_erd/domain.rb test/unit/domain_test.rb
git commit -m "Update Domain to scan and parse Ruby files instead of reflecting on ActiveRecord"
```

---

## Task 5: Update Entity class to represent Ruby classes

**Files:**
- Modify: `lib/rails_erd/domain/entity.rb`
- Create: `test/unit/entity_test.rb`

**Step 1: Write the failing test**

Create `test/unit/entity_test.rb`:

```ruby
require File.expand_path('../../test_helper', __FILE__)

module RailsERD
  class EntityTest < ActiveSupport::TestCase
    def test_creates_entity_from_parsed_class
      parsed = {
        class_name: 'UserService',
        superclass: 'BaseService',
        public_methods: [
          { name: :process, signature: 'process(user)', class_method: false },
          { name: :call, signature: 'call', class_method: true }
        ]
      }

      domain = Object.new # Mock domain
      entity = Domain::Entity.from_parsed_class(parsed, domain)

      assert_equal 'UserService', entity.name
      assert_equal false, entity.generalized?
    end

    def test_marks_abstract_classes_as_generalized
      parsed = {
        class_name: 'ApplicationRecord',
        superclass: nil,
        public_methods: []
      }

      domain = Object.new
      entity = Domain::Entity.from_parsed_class(parsed, domain)

      # ApplicationRecord, ApplicationController, etc. should be generalized
      assert entity.generalized?
    end
  end
end
```

**Step 2: Run test to verify it fails**

Run: `ruby test/unit/entity_test.rb`
Expected: FAIL with "undefined method `from_parsed_class'"

**Step 3: Update Entity class**

In `lib/rails_erd/domain/entity.rb`, replace the entire class with:

```ruby
module RailsERD
  class Domain
    class Entity
      attr_reader :domain, :name, :parsed_class

      def self.from_parsed_class(parsed, domain)
        new(domain, parsed)
      end

      def initialize(domain, parsed)
        @domain = domain
        @parsed_class = parsed
        @name = parsed[:class_name]
      end

      def generalized?
        # Mark framework base classes as generalized
        %w[ApplicationRecord ApplicationController ApplicationMailer ApplicationJob
           ActionController::Base ActiveRecord::Base ActionMailer::Base ActiveJob::Base
           Object BasicObject].include?(name)
      end

      def attributes
        @attributes ||= parsed_class[:public_methods].map do |method_data|
          Attribute.new(self, method_data)
        end
      end

      def ==(other)
        other.is_a?(Entity) && other.name == name
      end

      def <=>(other)
        name <=> other.name
      end

      def to_s
        name
      end
    end
  end
end
```

**Step 4: Run test to verify it passes**

Run: `ruby test/unit/entity_test.rb`
Expected: All tests PASS

**Step 5: Commit**

```bash
git add lib/rails_erd/domain/entity.rb test/unit/entity_test.rb
git commit -m "Update Entity to represent Ruby classes instead of ActiveRecord models"
```

---

## Task 6: Update Attribute class to represent methods

**Files:**
- Modify: `lib/rails_erd/domain/attribute.rb`
- Create: `test/unit/attribute_test.rb`

**Step 1: Write the failing test**

Create `test/unit/attribute_test.rb`:

```ruby
require File.expand_path('../../test_helper', __FILE__)

module RailsERD
  class AttributeTest < ActiveSupport::TestCase
    def test_creates_attribute_from_method_data
      method_data = {
        name: :process_order,
        signature: 'process_order(order, options = {})',
        class_method: false
      }

      entity = Object.new # Mock entity
      attribute = Domain::Attribute.new(entity, method_data)

      assert_equal 'process_order(order, options = {})', attribute.name
      assert_equal false, attribute.class_method?
    end

    def test_identifies_class_methods
      method_data = {
        name: :call,
        signature: 'call',
        class_method: true
      }

      entity = Object.new
      attribute = Domain::Attribute.new(entity, method_data)

      assert attribute.class_method?
    end
  end
end
```

**Step 2: Run test to verify it fails**

Run: `ruby test/unit/attribute_test.rb`
Expected: FAIL with "wrong number of arguments"

**Step 3: Update Attribute class**

In `lib/rails_erd/domain/attribute.rb`, replace the entire class with:

```ruby
module RailsERD
  class Domain
    class Attribute
      attr_reader :entity, :method_data

      def initialize(entity, method_data)
        @entity = entity
        @method_data = method_data
      end

      def name
        method_data[:signature]
      end

      def class_method?
        method_data[:class_method] || false
      end

      def ==(other)
        other.is_a?(Attribute) && other.name == name && other.entity == entity
      end

      def <=>(other)
        name <=> other.name
      end

      def to_s
        prefix = class_method? ? '+ ' : '- '
        "#{prefix}#{name}"
      end
    end
  end
end
```

**Step 4: Run test to verify it passes**

Run: `ruby test/unit/attribute_test.rb`
Expected: All tests PASS

**Step 5: Commit**

```bash
git add lib/rails_erd/domain/attribute.rb test/unit/attribute_test.rb
git commit -m "Update Attribute to represent methods instead of database columns"
```

---

## Task 7: Update Relationship class for method calls

**Files:**
- Modify: `lib/rails_erd/domain/relationship.rb`
- Create: `test/unit/relationship_test.rb`

**Step 1: Write the failing test**

Create `test/unit/relationship_test.rb`:

```ruby
require File.expand_path('../../test_helper', __FILE__)

module RailsERD
  class RelationshipTest < ActiveSupport::TestCase
    def test_creates_relationship_from_method_call
      domain = Object.new
      source = Object.new
      destination = Object.new

      relationship = Domain::Relationship.from_method_call(domain, source, destination)

      assert_equal source, relationship.source
      assert_equal destination, relationship.destination
    end
  end
end
```

**Step 2: Run test to verify it fails**

Run: `ruby test/unit/relationship_test.rb`
Expected: FAIL with "undefined method `from_method_call'"

**Step 3: Update Relationship class**

In `lib/rails_erd/domain/relationship.rb`, replace the entire class with:

```ruby
module RailsERD
  class Domain
    class Relationship
      attr_reader :domain, :source, :destination

      def self.from_method_call(domain, source, destination)
        new(domain, source, destination)
      end

      def initialize(domain, source, destination)
        @domain = domain
        @source = source
        @destination = destination
      end

      # For class diagrams, relationships are always direct
      def indirect?
        false
      end

      # Cardinality is not applicable for method calls
      # But keep for compatibility with diagram generators
      def cardinality
        Cardinality.new(Cardinality::N, Cardinality::N)
      end

      def ==(other)
        other.is_a?(Relationship) &&
          other.source == source &&
          other.destination == destination
      end

      def to_s
        "#{source} -> #{destination}"
      end
    end
  end
end
```

**Step 4: Run test to verify it passes**

Run: `ruby test/unit/relationship_test.rb`
Expected: All tests PASS

**Step 5: Commit**

```bash
git add lib/rails_erd/domain/relationship.rb test/unit/relationship_test.rb
git commit -m "Update Relationship to represent method calls between classes"
```

---

## Task 8: Update Specialization for class inheritance

**Files:**
- Modify: `lib/rails_erd/domain/specialization.rb`

**Step 1: Review existing Specialization class**

Run: `cat lib/rails_erd/domain/specialization.rb`

The Specialization class already works correctly for class inheritance. It just needs the generalized and specialized entities.

**Step 2: Verify it works with new Entity implementation**

The existing implementation should work without changes. The Specialization represents inheritance which is the same concept for both ERD and class diagrams.

**Step 3: Skip changes**

No changes needed. The Specialization class already correctly represents inheritance relationships.

---

## Task 9: Update Graphviz diagram generator

**Files:**
- Modify: `lib/rails_erd/diagram/graphviz.rb`
- Test manually with example

**Step 1: Update entity rendering**

In `lib/rails_erd/diagram/graphviz.rb`, find the `process_entity` method and update to handle methods instead of columns. The method should already work since it iterates over `entity.attributes`, but we may need to adjust formatting.

Review current implementation:
Run: `grep -A 20 "def process_entity" lib/rails_erd/diagram/graphviz.rb`

**Step 2: Update attribute display**

The attributes are now method signatures. Ensure they display correctly in the class boxes. Look for where attributes are formatted and ensure method signatures show properly.

In `lib/rails_erd/diagram/graphviz.rb`, update any attribute formatting to handle method signatures.

**Step 3: Update relationship arrows**

Relationships now represent method calls, not database associations. Update arrow labels and styles if needed.

Find relationship rendering code:
Run: `grep -A 10 "def process_relationship" lib/rails_erd/diagram/graphviz.rb`

**Step 4: Test manually**

Create a test script in `test_class_diagram.rb`:

```ruby
require './lib/rails-erd'

# This will be tested after CLI is updated
```

**Step 5: Commit**

```bash
git add lib/rails_erd/diagram/graphviz.rb
git commit -m "Update Graphviz generator to render class diagrams"
```

---

## Task 10: Update Mermaid diagram generator

**Files:**
- Modify: `lib/rails_erd/diagram/mermaid.rb`

**Step 1: Update entity rendering**

In `lib/rails_erd/diagram/mermaid.rb`, find where entities are rendered. Update to show methods instead of database columns.

Mermaid class diagram syntax:
```
classDiagram
  class ClassName {
    +method_name()
    -private_method()
  }
```

**Step 2: Update relationship rendering**

Update relationships to show method call dependencies:
```
ClassName --> OtherClass : calls
```

**Step 3: Review and update**

Read the current implementation:
Run: `cat lib/rails_erd/diagram/mermaid.rb`

Update as needed to properly render class diagrams.

**Step 4: Commit**

```bash
git add lib/rails_erd/diagram/mermaid.rb
git commit -m "Update Mermaid generator to render class diagrams"
```

---

## Task 11: Update CLI and options

**Files:**
- Modify: `lib/rails_erd/cli.rb`
- Modify: `bin/erd`

**Step 1: Update help text**

In `lib/rails_erd/cli.rb`, update the help text to reflect class diagrams instead of ERD:

Change references from:
- "Entity-Relationship Diagram" → "Class Diagram"
- "models" → "classes"
- "associations" → "method calls"

**Step 2: Add --paths option**

Add a new option to specify which directories to scan:

```ruby
option :paths do
  short '-p'
  long '--paths=app/models,lib/services'
  desc 'Comma-separated list of paths to scan for Ruby files (default: app,lib)'
  default nil
end
```

**Step 3: Update default options**

In `lib/rails_erd.rb`, update default options:

```ruby
:title => 'Class Diagram',
```

**Step 4: Test CLI**

Run: `bundle exec bin/erd --help`
Expected: Help text shows updated descriptions

**Step 5: Commit**

```bash
git add lib/rails_erd/cli.rb lib/rails_erd.rb bin/erd
git commit -m "Update CLI for class diagram generation"
```

---

## Task 12: Update gemspec and README

**Files:**
- Modify: `rails-erd.gemspec`
- Modify: `README.md`

**Step 1: Update gemspec description**

In `rails-erd.gemspec`, update:

```ruby
spec.summary = "Generate class diagrams from Ruby code"
spec.description = "Automatically generate class diagrams showing Ruby classes, their methods, and method call relationships. Supports Graphviz and Mermaid output formats."
```

**Step 2: Update README**

Replace the README content to describe class diagram generation:

- Change title to "Ruby Class Diagram Generator"
- Update description and examples
- Show sample output with classes and methods
- Update installation and usage instructions
- Document new --paths option

**Step 3: Bump version to 3.0.0**

In `lib/rails_erd/version.rb`:

```ruby
VERSION = "3.0.0"
```

This is a breaking change from ERD to class diagrams.

**Step 4: Commit**

```bash
git add rails-erd.gemspec README.md lib/rails_erd/version.rb
git commit -m "Update documentation for class diagram generator v3.0.0"
```

---

## Task 13: Integration testing

**Files:**
- Create: `test/fixtures/sample_app/app/models/user.rb`
- Create: `test/fixtures/sample_app/app/services/user_service.rb`
- Create: `test/integration/class_diagram_test.rb`

**Step 1: Create fixture application**

Create `test/fixtures/sample_app/app/models/user.rb`:

```ruby
class User
  def save
    UserService.persist(self)
  end

  def self.find(id)
    new
  end
end
```

Create `test/fixtures/sample_app/app/services/user_service.rb`:

```ruby
class UserService
  def self.persist(user)
    true
  end

  def self.notify(user)
    UserMailer.welcome(user)
  end
end
```

Create `test/fixtures/sample_app/app/mailers/user_mailer.rb`:

```ruby
class UserMailer
  def self.welcome(user)
    "Welcome email"
  end
end
```

**Step 2: Write integration test**

Create `test/integration/class_diagram_test.rb`:

```ruby
require File.expand_path('../../test_helper', __FILE__)

module RailsERD
  class ClassDiagramTest < ActiveSupport::TestCase
    def setup
      @fixture_path = File.expand_path('../../fixtures/sample_app', __FILE__)
    end

    def test_generates_domain_from_fixture_app
      domain = Domain.generate(root: @fixture_path)

      # Should find all three classes
      assert_equal 3, domain.entities.length

      # Should have User entity
      user = domain.entities.find { |e| e.name == 'User' }
      assert user
      assert user.attributes.any? { |a| a.name.include?('save') }
      assert user.attributes.any? { |a| a.name.include?('find') }

      # Should detect relationships
      # User calls UserService
      rel = domain.relationships.find do |r|
        r.source.name == 'User' && r.destination.name == 'UserService'
      end
      assert rel, "Should detect User -> UserService relationship"
    end

    def test_generates_graphviz_diagram
      domain = Domain.generate(root: @fixture_path)
      diagram = Diagram::Graphviz.new(domain, filetype: 'dot')

      output = StringIO.new
      diagram.instance_variable_set(:@output, output)
      diagram.create

      dot_content = output.string
      assert_includes dot_content, 'User'
      assert_includes dot_content, 'UserService'
      assert_includes dot_content, 'UserMailer'
    end

    def test_generates_mermaid_diagram
      domain = Domain.generate(root: @fixture_path)
      diagram = Diagram::Mermaid.new(domain)

      output = diagram.create

      assert_includes output, 'classDiagram'
      assert_includes output, 'User'
      assert_includes output, 'UserService'
    end
  end
end
```

**Step 3: Run integration tests**

Run: `ruby test/integration/class_diagram_test.rb`
Expected: All tests PASS

**Step 4: Fix any failures**

If tests fail, debug and fix issues in the domain loading or diagram generation.

**Step 5: Commit**

```bash
git add test/fixtures/ test/integration/class_diagram_test.rb
git commit -m "Add integration tests for class diagram generation"
```

---

## Task 14: Run full test suite

**Step 1: Run all tests**

Run: `bundle exec rake test`
Expected: All tests PASS

**Step 2: Fix any failures**

Review and fix any broken tests. Some old tests may need updating since we changed from ERD to class diagrams.

**Step 3: Remove obsolete tests**

Remove or update tests that are specific to ActiveRecord ERD generation and no longer applicable.

**Step 4: Commit fixes**

```bash
git add test/
git commit -m "Update test suite for class diagram functionality"
```

---

## Task 15: Manual end-to-end testing

**Step 1: Test on a real Rails application**

Navigate to a Rails app (or create a minimal one):

```bash
cd /path/to/rails/app
bundle exec /path/to/rails-erd/bin/erd
```

Expected: Generates class diagram PDF

**Step 2: Test Mermaid output**

```bash
bundle exec erd --generator=mermaid --filetype=md
```

Expected: Generates Mermaid markdown file

**Step 3: Test --paths option**

```bash
bundle exec erd --paths=app/models,app/services
```

Expected: Only includes classes from specified paths

**Step 4: Verify diagram quality**

Open the generated PDF/PNG and verify:
- Classes are shown as boxes
- Public methods are listed in each class
- Arrows show method call relationships
- Inheritance is shown with different arrow style

**Step 5: Document any issues**

Create GitHub issues for any bugs or improvements needed.

---

## Completion Checklist

- [ ] Parser gem dependency added
- [ ] RubyParser implemented and tested
- [ ] StaticAnalyzer implemented and tested
- [ ] Domain class updated to scan Ruby files
- [ ] Entity class represents Ruby classes
- [ ] Attribute class represents methods
- [ ] Relationship class represents method calls
- [ ] Specialization works with inheritance
- [ ] Graphviz generator updated
- [ ] Mermaid generator updated
- [ ] CLI updated with new options
- [ ] Documentation updated (README, gemspec)
- [ ] Integration tests pass
- [ ] Full test suite passes
- [ ] Manual testing on real Rails app successful

---

## Notes

- This is a breaking change (v3.0.0)
- Static analysis has limitations - it won't catch all method calls
- Focus on clarity and usability over perfect detection
- Consider adding configuration for method visibility (public/private/protected) in future
- Could enhance with optional runtime instrumentation in future versions
