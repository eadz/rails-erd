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
