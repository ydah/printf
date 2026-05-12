RUBY ?= ruby

.PHONY: test
test:
	$(RUBY) -Ilib:test test/all_test.rb
