require_relative '../../spec_helper'
require_relative 'fixtures/classes'
require_relative 'shared/strip'

describe "String#rstrip" do
  it_behaves_like :string_strip, :rstrip

  it "returns a copy of self with trailing whitespace removed" do
    "  hello  ".rstrip.should == "  hello"
    "  hello world  ".rstrip.should == "  hello world"
    "  hello world \n\r\t\n\v\r".rstrip.should == "  hello world"
    "hello".rstrip.should == "hello"
    "hello\x00".rstrip.should == "hello"
  end

  it "returns a copy of self with all trailing whitespace and NULL bytes removed" do
    "\x00 \x00hello\x00 \x00".rstrip.should == "\x00 \x00hello"
  end

  ruby_version_is ''...'2.7' do
    it "taints the result when self is tainted" do
      "".taint.rstrip.should.tainted?
      "ok".taint.rstrip.should.tainted?
      "ok    ".taint.rstrip.should.tainted?
    end
  end
end

# NATFIXME: implement mutating rstrip! method
xdescribe "String#rstrip!" do
  it "modifies self in place and returns self" do
    a = "  hello  "
    a.rstrip!.should equal(a)
    a.should == "  hello"
  end

  it "modifies self removing trailing NULL bytes and whitespace" do
    a = "\x00 \x00hello\x00 \x00"
    a.rstrip!
    a.should == "\x00 \x00hello"
  end

  it "returns nil if no modifications were made" do
    a = "hello"
    a.rstrip!.should == nil
    a.should == "hello"
  end

  it "raises a FrozenError on a frozen instance that is modified" do
    -> { "  hello  ".freeze.rstrip! }.should raise_error(FrozenError)
  end

  # see [ruby-core:23666]
  it "raises a FrozenError on a frozen instance that would not be modified" do
    -> { "hello".freeze.rstrip! }.should raise_error(FrozenError)
    -> { "".freeze.rstrip!      }.should raise_error(FrozenError)
  end
end
