require 'rubygems'
require 'puppet'

module Puppet_X
module Bobtfish
class Ec2_api < Puppet::Provider
  HAVE_AWS_SDK = begin
    require 'aws-sdk'
    AWS.config(
     :logger        => Logger.new($stdout),
     :log_formatter => AWS::Core::LogFormatter.colored,
     :log_level     => :debug) if ENV['AWS_DEBUG'] == '1'
    true
  rescue LoadError
    STDERR.puts "Coudln't load AWS SDK gem"
    false
  end

  confine :true => HAVE_AWS_SDK

  desc "Helper for Providers which use the EC2 API"
  self.initvars

  def self.instances_class
    raise "#instances_class not implemented"
  end

  def self.instances
    describe_call = instances_class.send :describe_call_name
    set_call      = :"#{instances_class.send :inflected_name}_set"
    id_call       = :"#{instances_class.send :inflected_name}_id"

    @instance_names ||= []
    @instances      ||= regions.map do |region_name|
      region   = ec2.regions[region_name]
      item_set = region.client.send(describe_call).send(set_call)

      item_set.map do |item_attrs|
        item = preload(region, item_attrs, describe_call, id_call)
        name = [region_name, item.tags['Name'] || item.id].join('/')

        raise "#{item} : #{name} is a duplicate" if @instance_names.include? name
        @instance_names << name

        new_from_aws(region_name, item, item.tags.clone)
      end
    end.flatten.compact.sort_by{|i| i.aws_item.id}
  rescue Exception => e
    STDERR.puts "EMERGENCY BAIL OUT"
    STDERR.puts "probably due to amazon API errors in prefetch (are you over the limits?)"
    STDERR.puts e.to_s
    STDERR.puts e.backtrace[0..5]
    Kernel.exit! 1
  end

  def self.reset_instances!
    @instances = nil
    @instance_names = nil
  end

  def self.preload(region, item_attrs, describe_call, id_call)
    item = instances_class.new_from(
      describe_call, item_attrs, item_attrs.send(id_call), :config => region.config)

    item_attrs.keys.each {|k| item.define_singleton_method(:"pre_#{k}") { item_attrs[k] } }

    original_tags = item.tags
    item.define_singleton_method(:set_tags) {|tags| original_tags.set(tags) }

    item_tags = item.pre_tag_set.inject({}) {|tags, tag| tags.merge!(tag[:key] => tag[:value]) }
    item.define_singleton_method(:tags) { item_tags }

    item
  end

  def self.prefetch(resources)
    instances.each do |provider|
      if resource = resources[provider.name]
        resource.provider = provider
      end
    end
  rescue Exception => e
    STDERR.puts "EMERGENCY BAIL OUT"
    STDERR.puts "probably due to amazon API errors in prefetch (are you over the limits?)"
    STDERR.puts e.to_s
    STDERR.puts e.backtrace[0..5]
    Kernel.exit! 1
  end

  def self.lookup(type, id_or_name)
    Puppet::Type.type(type).provider(:api).
      instances.find {|res| [res.name, res.aws_item.id].include? id_or_name }
  end

  def lookup(type, id_or_name)
    self.class.lookup(type, id_or_name)
  end

  def self.read_only(*methods)
    methods.each do |ro_method|
      define_method("#{ro_method}=") do |v|
        fail "Can't change '#{ro_method}' for '#{name}' - property is read-only once #{resource.type} resource is created."
      end
    end
  end

  def self.name_or_id(item)
    return unless item
    item.tags.to_h['Name'] || item.id
  end
  def name_or_id(item)
    self.class.name_or_id(item)
  end

  def wait_until_status(item, status, limit=1000)
    sleep 1 while item.state != state && (limit-=1) > 0
  end

  def wait_until_state(item, state, limit=1000)
    while limit > 0
      limit -= 1
      current_state = block_given? ? yield : item.state
      return true if current_state == state
      sleep 1
    end

    false
  end

  def tag_with_name(item, name)
    item.add_tag 'Name', :value => name
  end

  def get_creds
    self.class.default_creds
  end

  def self.default_creds
    { :access_key_id => (ENV['AWS_ACCESS_KEY_ID']||ENV['AWS_ACCESS_KEY']),
      :secret_access_key => (ENV['AWS_SECRET_ACCESS_KEY']||ENV['AWS_SECRET_KEY']) }
  end

  def self.amazon_thing(which); which.new; end

  def self.iam; @@iam ||= AWS::IAM.new; end
  def iam; self.class.iam; end

  def self.ec2; @@ec2 ||= AWS::EC2.new; end
  def ec2; self.class.ec2; end

  def self.r53; @@r53 ||= AWS::Route53.new; end
  def r53; self.class.r53; end

  def self.elb(region=nil); (@@elb ||= {})[region] ||= AWS::ELB.new(:region => region); end
  def elb(region=nil); self.class.elb(region); end

  def self.rds(region=nil); (@@rds ||= {})[region] ||= AWS::RDS.new(:region => region); end
  def rds(region=nil); self.class.rds(region); end

  def self.elcc(region=nil); (@@elcc ||= {})[region] ||= AWS::ElastiCache.new(:region => region); end
  def elcc(region=nil); self.class.elcc(region); end

  def self.regions
    @@regions ||=  if ENV['AWS_REGION'] and not ENV['AWS_REGION'].empty?
      [ENV['AWS_REGION']]
    elsif HAVE_AWS_SDK
      ec2.regions.collect { |r| r.name }
    else
      []
    end
  end

  def regions
    self.class.regions
  end

  def tags=(newtags)
    string_values= newtags.inject({}){|h,(k,v)| h.merge!(k => v.to_s)}
    @property_hash[:aws_item].set_tags(string_values)
    @property_hash[:tags] = newtags
  end

  def find_vpc_item_by_name(name)
    self.class.find_vpc_item_by_name(name)
  end
  def self.find_vpc_item_by_name(name)
    res = Puppet::Type.type(:aws_vpc).provider(:api).instances.
      find {|vpc| vpc.name == name || vpc.aws_item.id == name}
    res.aws_item if res
  end

  def find_region_name_for_vpc_name(name)
    self.class.find_region_name_for_vpc_name(name)
  end
  def self.find_region_name_for_vpc_name(name)
    find_vpc_item_by_name(name).client.instance_variable_get('@region')
  end

  def self.find_hosted_zone_by_name(name)
    r53.hosted_zones.find{|zone| zone.name == name }
  end

  def self.find_instance_profile_by_id(id)
    # No there really isn't a direct ID lookup API call, go figure
    iam.client.list_instance_profiles[:instance_profiles].find do |profile|
      profile[:instance_profile_id] == id
    end
  end

  def flush
  end

  def exists?
    @property_hash[:ensure] == :present
  end

  def aws_item
    @property_hash[:aws_item]
  end

  def vpc=(vpc_name)
    vpc = find_vpc_item_by_name(vpc_name)
    if vpc.nil?
      fail("Cannot find vpc #{vpc_name}")
    end
    @property_hash[:aws_item].attach(vpc)
    @property_hash[:vpc] = vpc_name
  end
end
end # module Bobtfish
end # module Puppet_X
