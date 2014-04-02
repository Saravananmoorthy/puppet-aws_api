require File.expand_path(File.join(File.dirname(__FILE__), '..', '..', '..', 'puppet_x', 'bobtfish', 'ec2_api.rb'))

Puppet::Type.type(:aws_subnet).provide(:api, :parent => Puppet_X::Bobtfish::Ec2_api) do
  mk_resource_methods

  def self.vpcs_for_region(region, access_key, secret_key)
    ec2(access_key, secret_key).regions[region].vpcs
  end
  def self.new_from_aws(vpc_id, item)
    tags = item.tags.to_h
    name = tags.delete('Name') || item.id
    new(
      :aws_item => item,
      :name     => name,
      :id       => item.id,
      :ensure   => :present,
      :vpc      => vpc_id,
      :cidr     => item.cidr_block,
      :az       => item.availability_zone_name,
      :tags     => tags.to_hash
    )
  end
  def exists?
    puts "Trying to work out if subnet #{resource[:name]} works"
    if resource.catalog # Normal run, we have a catalog and so can look up credentials
      account = resource.catalog.resources.find do |r|
        r.is_a?(Puppet::Type.type(:aws_credential)) && r[:name] == resource[:account]
      end
      if ! account && resource[:account] != 'default'
        raise("No account #{resource[:account]} found, did you make an aws_credential {}")
      end    
      puts "Username is #{account[:user]} Password is #{account[:password]}"
      e = ec2(account[:user], account[:password])
      region_names = e.regions.collect { |r| r.name }
      subnets = region_names.collect { |r_name| e.regions[r_name].subnets }.flatten
      subnets.find { |subnet| subnet.id == resource[:name] || subnet.tags['Name'] == resource[:name] }
    else
      puts "This is a 'puppet resource' run, no catalog - have to get by on default credentials"
      true # We came here as self.instances returned a thing, so it's gotta exist :)
    end
  end
  def self.instances
    regions.collect do |region_name|
      vpcs_for_region(region_name, *default_credentials).collect do |vpc|
        vpc_name = name_or_id vpc
        vpc.subnets.collect do |item|
          new_from_aws(vpc_name, item)
        end
      end.flatten
    end.flatten
  end
  [:vpc, :cidr].each do |ro_method|
    define_method("#{ro_method}=") do |v|
      fail "Cannot manage #{ro_method} is read-only once a subnet is created"
    end
  end
  def tags=(value)
    fail "Set tags not implemented yet"
  end
  def create
    begin
      vpc = find_vpc_item_by_name(resource[:vpc])
      subnet = vpc.subnets.create(resource[:cidr])
      wait_until_state subnet, :available
      tag_with_name subnet, resource[:name]
      tags = resource[:tags] || {}
      tags.each { |k,v| subnet.add_tag(k, :value => v) }
      subnet
    rescue Exception => e
      fail e
    end
  end
  def destroy
    @property_hash[:aws_item].delete
    @property_hash[:ensure] = :absent
  end
end

