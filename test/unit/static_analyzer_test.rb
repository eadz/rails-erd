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
