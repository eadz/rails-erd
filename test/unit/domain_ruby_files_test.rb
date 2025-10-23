require File.expand_path('../../test_helper', __FILE__)
require 'tmpdir'
require 'fileutils'

module RailsERD
  class DomainRubyFilesTest < ActiveSupport::TestCase
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
