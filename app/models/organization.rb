class Organization < ActiveRecord::Base
  include Permissions
  include Processable
  include GlobalId
  include Async
  include SecureSerialize
  include Notifier
  secure_serialize :settings
  before_save :generate_defaults
  after_save :touch_parent
  include Replicate
  
  # cache should be invalidated if:
  # - a manager/assistant is added or removed
  add_permissions('view') { self.settings && self.settings['public'] == true }
  add_permissions('view', 'edit') {|user| self.settings['org_access'] != false && self.assistant?(user) }
  add_permissions('view', 'edit', 'manage') {|user| self.settings['org_access'] != false && self.manager?(user) }
  add_permissions('view', 'edit', 'manage') {|user| self.upstream_manager?(user) }
  add_permissions('view', 'edit', 'manage', 'update_licenses', 'manage_subscription') {|user| Organization.admin && Organization.admin.manager?(user) }
  add_permissions('view') {|user| self.supervisor?(user) }
  add_permissions('view') {|user| self.settings['org_access'] == false && self.manager?(user) }
  add_permissions('delete') {|user| Organization.admin && !self.admin && Organization.admin.manager?(user) }
  cache_permissions

  def generate_defaults
    self.settings ||= {}
    self.settings['name'] ||= "Unnamed Organization"
    if self.settings['saml_metadata_url']
      self.external_auth_key = GoSecure.sha512(self.settings['saml_metadata_url'], 'external_auth_key')
    else
      self.external_auth_key = nil
    end
    @processed = false
    true
  end
  
  def self.admin
    self.where(:admin => true).first
  end
  
  def log_sessions
    sessions = LogSession.where(:log_type => 'session')
    if !self.admin
      user_ids = self.users.select{|u| !u.private_logging? }.map(&:id)
      sessions = sessions.where(:user_id => user_ids)
    end
    sessions.where(['started_at > ? AND started_at <= ?', 6.months.ago, Time.now]).order('started_at DESC')
  end
  
  def purchase_history
    ((self.settings || {})['purchase_events'] || []).reverse
  end
  
  def add_manager(user_key, full=false)
    user = User.find_by_path(user_key)
    raise "invalid user, #{user_key}" unless user
#     user.settings ||= {}
#     user.settings['manager_for'] ||= {}
#     user.settings['manager_for'][self.global_id] = {'full_manager' => !!full, 'added' => Time.now.iso8601}
    user.settings['preferences']['role'] = 'supporter'
    user.settings['possible_admin'] = true
    user.assert_current_record!
    user.save_with_sync('add_manager')
#     self.attach_user(user, 'manager')
    # TODO: trigger notification
    if (user.grace_period? || user.modeling_only?) && !Organization.sponsored?(user)
      user.update_subscription({
        'subscribe' => true,
        'subscription_id' => "free_auto_adjusted:#{self.global_id}",
        'token_summary' => "Automatically-set Supporter Account",
        'plan_id' => 'slp_monthly_granted'
      })
    end

    link = UserLink.generate(user, self, 'org_manager')
    link.data['state']['added'] ||= Time.now.iso8601
    link.data['state']['full_manager'] = true if full
    link.save!
    self.schedule(:org_assertions, user.global_id, 'manager')
    self.touch
    true
  rescue ActiveRecord::StaleObjectError
    self.schedule(:add_manager, user_key, full)
  end

  def org_assertions(user_id, user_type)
    if user_type == 'manager'
      user = User.find_by_path(user_id)
      if user && user.org_supporter?(true)
        user.settings['possibly_premium_supporter'] = true
        user.settings['pending'] = false
        user.save
      end
    end
    if user_type == 'user' || user_type == 'supervisor' || user_id == 'all'  
      if self.settings['include_extras']
        # users = []
        # if user_id == 'all'
        #   users += self.supervisors.select{|u| !self.pending_supervisor?(u) }
        #   users += self.sponsored_users.select{|u| !self.pending_user?(u) }
        #   users += self.eval_users.select{|u| !self.pending_user?(u) }
        # else
        #   user = User.find_by_global_id(user_id)
        #   if user
        #     if user_type == 'user' && self.sponsored_users.include?(user) && !self.pending_user?(user)
        #       users = [user]
        #     elsif user_type == 'supervisor' && self.supervisors.include?(user) && !self.pending_supervisor?(user)
        #       users = [user]
        #     end
        #   end
        # end
        # users.each do |user|
        #   # self.settings['extras_activations'] ||= []
        #   # if !user.reload.subscription_hash['extras_enabled']
        #   #   User.purchase_extras({'user_id' => user.global_id, 'source' => 'org_added'})
        #   #   self.settings['extras_activations'] << {user_id: user.global_id, activated_at: Time.now.iso8601}
        #   # end
        #   # self.save
        # end
      end
    end
  end
  
  def remove_manager(user_key)
    user = User.find_by_path(user_key)
    raise "invalid user, #{user_key}" unless user
#     user.settings ||= {}
#     user.settings['manager_for'] ||= {}
#     user.settings['manager_for'].delete(self.global_id)
    self.detach_user(user, 'manager')
    # TODO: trigger notification
#     user.assert_current_record!
#     user.save_with_sync('remove_manager')
    self.touch
    true
  rescue ActiveRecord::StaleObjectError
    self.schedule(:remove_manager, user_key)
  end
  
  def add_supervisor(user_key, pending=true, premium=false)
    user = User.find_by_path(user_key)
    raise "invalid user, #{user_key}" unless user
    if user.settings['authored_organization_id'] && user.settings['authored_organization_id'] == self.global_id && user.created_at > 2.weeks.ago
      pending = false
    end
    if premium
      premium_supporter_count = self.premium_supervisors.count
      raise "no premium supporter licenses available" if ((self.settings || {})['total_supervisor_licenses'] || 0) <= premium_supporter_count
    end

    #     user.settings ||= {}
#     user.settings['supervisor_for'] ||= {}
#     user.settings['supervisor_for'][self.global_id] = {'pending' => pending, 'added' => Time.now.iso8601}
    user.settings['preferences']['role'] = 'supporter' if !pending
    user.settings['possibly_premium_supporter'] = true if premium
    user.settings['pending'] = false
    user.assert_current_record!
    user.save_with_sync('add_supervisor')
#     self.attach_user(user, 'supervisor')
    if !pending
      if (user.grace_period? || user.modeling_only?) && !Organization.sponsored?(user)
        user.update_subscription({
          'subscribe' => true,
          'subscription_id' => "free_auto_adjusted:#{self.global_id}",
          'token_summary' => "Automatically-set Supporter Account",
          'plan_id' => 'slp_monthly_free'
        })
      end
    end
    link = UserLink.generate(user, self, 'org_supervisor')
    link.data['state']['pending'] = pending unless link.data['state']['pending'] == false
    link.data['state']['premium'] = premium unless link.data['state']['premium'] == true
    link.data['state']['added'] ||= Time.now.iso8601
    link.save
    self.schedule(:org_assertions, user.global_id, 'supervisor')
    self.touch
    true
  rescue ActiveRecord::StaleObjectError
    self.schedule(:add_supervisor, user_key, pending, premium)
  end
  
  def approve_supervisor(user)
    links = UserLink.links_for(user).select{|l| l['type'] == 'org_supervisor' && l['record_code'] == Webhook.get_record_code(self) }
    user.settings['preferences']['role'] = 'supporter'
    user.settings['pending'] = false
    user.assert_current_record!
    user.save_with_sync('add_supervisor')
    if (user.grace_period? || user.modeling_only?) && !Organization.sponsored?(user)
      user.update_subscription({
        'subscribe' => true,
        'subscription_id' => "free_auto_adjusted:#{self.global_id}",
        'token_summary' => "Automatically-set Supporter Account",
        'plan_id' => 'slp_monthly_free'
      })
    end
    if links.length > 0
      link = UserLink.generate(user, self, 'org_supervisor')
      link.data['state']['pending'] = false
      link.save
      self.schedule(:org_assertions, user.global_id, 'supervisor')
    end
#     if user.settings['supervisor_for'] && user.settings['supervisor_for'][self.global_id]
#       self.add_supervisor(user.user_name, false)
#       user.settings['supervisor_for'][self.global_id]['pending'] = false
#     end
  end
  
  def reject_supervisor(user)
    # If subscription_id == free_auto_adjusted:#{self.global_id} then remove premium status
    if user.billing_state == :org_supporter && (user.settings['subscription'] || {})['subscription_id'] == "free_auto_adjusted:#{self.global_id}"
      user.update_subscription({
        'unsubscribe' => true,
        'subscription_id' => "free_auto_adjusted:#{self.global_id}"
      })
    end
    UserLink.remove(user, self, 'org_supervisor')
    self.schedule(:org_assertions, user.global_id, 'supervisor')
#     if user.settings['supervisor_for'] && user.settings['supervisor_for'][self.global_id]
#       self.remove_supervisor(user.user_name)
#       user.settings['supervisor_for'].delete(self.global_id)
#     end
  end
  
  def remove_supervisor(user_key)
    user = User.find_by_path(user_key)
    raise "invalid user, #{user_key}" unless user
    pending = !!UserLink.links_for(user).detect{|l| l['type'] == 'org_supervisor' && l['record_code'] == Webhook.get_record_code(self) && l['state']['pending'] }
    if !pending
      user.settings['past_purchase_durations'] ||= []
      org_code = Webhook.get_record_code(self)
      links = UserLink.links_for(user)
      links.select{|l| l['type'] == 'org_supervisor' && l['state']['added'] }.each do |link|
        added = (link['state']['added'] && Time.parse(link['state']['added'])) rescue nil
        if added
          user.settings['past_purchase_durations'] << {role: 'supporter', type: 'org', started: link['state']['added'], duration: (Time.now.to_i - added.to_i)}
        end
      end
      user.save
      # If subscription_id == free_auto_adjusted:#{self.global_id} then remove premium status
      if user.billing_state == :org_supporter && (user.settings['subscription'] || {})['subscription_id'] == "free_auto_adjusted:#{self.global_id}"
        user.update_subscription({
          'unsubscribe' => true,
          'subscription_id' => "free_auto_adjusted:#{self.global_id}"
        })
      end
    end
    self.detach_user(user, 'supervisor')

    notify('org_removed', {
      'user_id' => user.global_id,
      'user_type' => 'supervisor',
      'removed_at' => Time.now.iso8601
    }) unless pending
    OrganizationUnit.schedule(:remove_as_member, user_key, 'supervisor', self.global_id)
    true
  rescue ActiveRecord::StaleObjectError
    self.schedule(:remove_supervisor, user_key)
  end

  def add_subscription(user_key)
    user = User.find_by_path(user_key)
    raise "invalid user, #{user_key}" unless user
    link = UserLink.generate(user, self, 'org_subscription')
    link.save
#     self.attach_user(user, 'subscription')
    self.log_purchase_event({
      'type' => 'add_subscription',
      'user_name' => user.user_name,
      'user_id' => user.global_id
    })
    true
  end
  
  def remove_subscription(user_key)
    user = User.find_by_path(user_key)
    raise "invalid user, #{user_key}" unless user
    UserLink.remove(user, self, 'org_subscription')
    self.detach_user(user, 'subscription')
    self.log_purchase_event({
      'type' => 'remove_subscription',
      'user_name' => user.user_name,
      'user_id' => user.global_id
    })
    true
  end
  
  def log_purchase_event(args, do_save=true)
    self.settings ||= {}
    self.settings['purchase_events'] ||= []
    args['logged_at'] = Time.now.iso8601
    self.settings['purchase_events'] << args
    self.save if do_save
  end
  
  def manager?(user)
    links = UserLink.links_for(user)
    !!links.detect{|l| l['type'] == 'org_manager' && l['record_code'] == Webhook.get_record_code(self) && l['user_id'] == user.global_id && l['state']['full_manager'] }
  end

  def upstream_manager?(user)
    org_record_codes = self.upstream_orgs.map{|o| Webhook.get_record_code(o) }
    links = UserLink.links_for(user)
    !!links.detect{|l| l['type'] == 'org_manager' && org_record_codes.include?(l['record_code']) && l['user_id'] == user.global_id && l['state']['full_manager'] }
  end
  
  def assistant?(user)
    links = UserLink.links_for(user)
    !!links.detect{|l| l['type'] == 'org_manager' && l['record_code'] == Webhook.get_record_code(self) && l['user_id'] == user.global_id }
  end
  
  def supervisor?(user)
    links = UserLink.links_for(user)
    !!links.detect{|l| l['type'] == 'org_supervisor' && l['record_code'] == Webhook.get_record_code(self) && l['user_id'] == user.global_id }
  end
  
  def managed_user?(user)
    links = UserLink.links_for(user)
    res = !!links.detect{|l| l['type'] == 'org_user' && l['record_code'] == Webhook.get_record_code(self) && l['user_id'] == user.global_id }
    res
  end
  
  def sponsored_user?(user)
    links = UserLink.links_for(user)
    !!links.detect{|l| l['type'] == 'org_user' && l['record_code'] == Webhook.get_record_code(self) && l['user_id'] == user.global_id && l['state']['sponsored'] }
  end
  
  def eval_user?(user)
    links = UserLink.links_for(user)
    !!links.detect{|l| l['type'] == 'org_user' && l['record_code'] == Webhook.get_record_code(self) && l['user_id'] == user.global_id && l['state']['eval'] }
  end
  
  def pending_user?(user)
    links = UserLink.links_for(user)
    !!links.detect{|l| l['type'] == 'org_user' && l['record_code'] == Webhook.get_record_code(self) && l['user_id'] == user.global_id && l['state']['pending'] }
  end
  
  def pending_supervisor?(user)
    links = UserLink.links_for(user)
    !!links.detect{|l| l['type'] == 'org_supervisor' && l['record_code'] == Webhook.get_record_code(self) && l['user_id'] == user.global_id && l['state']['pending'] }
  end
  
  def self.sponsored?(user)
    links = UserLink.links_for(user)
    !!links.detect{|l| l['type'] == 'org_user' && l['user_id'] == user.global_id && l['state']['sponsored'] }
  end
  
  def self.managed?(user)
    links = UserLink.links_for(user)
    !!links.detect{|l| l['type'] == 'org_user' }
  end
  
  def self.supervisor?(user, premium=false)
    links = UserLink.links_for(user)
    !!links.detect{|l| l['type'] == 'org_supervisor' && (!premium || l['state']['premium'])}
  end
  
  def self.manager?(user)
    links = UserLink.links_for(user)
    res = !!links.detect{|l| l['type'] == 'org_manager' }
    if res && !user.settings['possible_admin']
      user.schedule(:update_setting, 'possible_admin', true)
    end
    res
  end
  
#   def self.upgrade_management_settings
#     User.where('managed_organization_id IS NOT NULL').each do |user|
#       org = user.managed_organization
#       user.settings['manager_for'] ||= {}
#       if org && !user.settings['manager_for'][org.global_id]
#         user.settings['manager_for'][org.global_id] = {
#           'full_manager' => !!user.settings['full_manager']
#         }
#       end
#       user.settings.delete('full_manager')
#       user.managed_organization_id = nil
#       user.save_with_sync('upgrade')
#     end
#     User.where('managing_organization_id IS NOT NULL').each do |user|
#       org = user.managing_organization
#       user.settings['managed_by'] ||= {}
#       if org && !user.settings['managed_by'][org.global_id]
#         user.settings['managed_by'][org.global_id] = {
#           'pending' => !!(user.settings['subscription'] && user.settings['subscription']['org_pending']),
#           'sponsored' => true
#         }
#       end
#       user.settings['subscription'].delete('org_pending') if user.settings['subscription']
#       user.managing_organization_id = nil
#       user.save_with_sync('upgrade2')
#     end
#     Organization.all.each do |org|
#       org.sponsored_users.each do |user|
#         org.attach_user(user, 'sponsored_user')
#       end
#       org.approved_users.each do |user|
#         org.attach_user(user, 'approved_user')
#       end
#     end
#   end
  
  def self.manager_for?(manager, user, include_admin_managers=true)
    return false unless manager && user
    manager_orgs = UserLink.links_for(manager).select{|l| l['type'] == 'org_manager' && l['user_id'] == manager.global_id && l['state']['full_manager'] }.map{|l| l['record_code'] }
    user_orgs = UserLink.links_for(user).select{|l| (l['type'] == 'org_user' || l['type'] == 'org_supervisor') && l['user_id'] == user.global_id && !l['state']['pending'] }.map{|l| l['record_code'] }
    if (manager_orgs & user_orgs).length > 0
      # if user and manager are part of the same org
      return true
    elsif manager_orgs.length > 0
      return true if include_admin_managers && admin_manager?(manager)
      if user_orgs.length > 0
        # check for any user orgs higher in the hierarchy
        more_user_record_codes = user_orgs.dup
        last_user_record_codes = []
        while last_user_record_codes.length != more_user_record_codes.length
          last_user_record_codes = more_user_record_codes.dup
          orgs = Organization.find_all_by_global_id(more_user_record_codes.map{|c| c.split(/:/)[1] })
          parent_ids = orgs.map{|o| o.parent_org_id }.compact.uniq
          more_user_record_codes += parent_ids.map{|id| "Organization:#{id}" }
          more_user_record_codes.uniq!
        end
        return true if (manager_orgs & more_user_record_codes).length > 0
      end
    end
    return true if include_admin_managers && admin_manager?(manager)
    return false
  end
  
  def touch_parent
    Organization.schedule(:load_domains, true) if self.custom_domain
    return unless self.parent_organization_id
    Organization.where(id: self.parent_organization_id).update_all(updated_at: Time.now)
    true
  end
  
  def parent_org_id
    return nil unless self.parent_organization_id
    self.related_global_id(self.parent_organization_id)
  end
  
  def upstream_orgs
    return [] unless self.parent_organization_id
    org_ids = []
    org = self
    while org && org.parent_org_id && !org_ids.include?(org.parent_org_id)
      org = Organization.find_by_global_id(org.parent_org_id)
      org_ids << org.global_id if org
      org_ids.uniq!
    end
    Organization.find_all_by_global_id(org_ids - [self.global_id])
  end
  
  def has_children?
    cache_key = "org/has_children/#{self.global_id}/#{self.updated_at.to_f}"
    cached_data = JSON.parse(Permissable.permissions_redis.get(cache_key)) rescue nil
    return cached_data['result'] if cached_data != nil
    # TODO: sharding
    res = Organization.where(parent_organization_id: self.id).count > 0
    expires = 72.hours.to_i
    Permissions.setex(Permissable.permissions_redis, cache_key, expires, {result: res}.to_json)
    res
  end
  
  def children_orgs
    return [] unless self.has_children?
    # TODO: sharding
    Organization.where(parent_organization_id: self.id).sort_by{|o| o.settings['name'] }
  end
  
  def downstream_orgs
    return [] unless self.has_children?
    list = [self]
    last_list = []
    while list.length != last_list.length
      last_list = list.dup
      list += list.map(&:children_orgs).flatten.compact
      list.uniq!
    end
    list - [self]
  end
  
  def self.admin_manager?(manager)
    manager_orgs = UserLink.links_for(manager).select{|l| l['type'] == 'org_manager' && l['user_id'] == manager.global_id && l['state']['full_manager'] }.map{|l| l['record_code'] }
    
    if manager_orgs.length > 0
      # if manager is part of the global org (the order of lookups seems weird, but should be a little more efficient)
      org = self.admin
      return true if org && manager_orgs.include?(Webhook.get_record_code(org))
    end
    false
  end
  
  def detach_user(user, user_type)
    user_types = [user_type]
    UserLink.remove(user, self, "org_#{user_type}")
    key = nil
    if user_type == 'user'
      user_types += ['sponsored_user', 'approved_user', 'eval_user']
      key = 'managed_by'
    elsif user_type == 'supervisor'
      key = 'supervisor_for'
    elsif user_type == 'manager'
      key = 'manager_for'
    end
    if key && user.settings[key] && user.settings[key][self.global_id]
      user.settings[key].delete(self.global_id)
      user.save
    end
    user_types.each do |type|
      self.settings['attached_user_ids'] ||= {}
      self.settings['attached_user_ids'][type] ||= []
      self.settings['attached_user_ids'][type].select!{|id| id != user.global_id }
    end
    self.save
    self.remove_extras_from_user(user.user_name)
  end
  
  def self.detach_user(user, user_type, except_org=nil)
    Organization.attached_orgs(user, true).each do |org|
      if org['type'] == user_type
        if !except_org || org['id'] != except_org.global_id
          org['org'].detach_user(user, user_type)
        end
      end
    end
  end
  
  def attached_users(user_type)
    links = UserLink.links_for(self)
    if user_type == 'user'
      links = links.select{|l| l['type'] == 'org_user' && !l['state']['eval'] }
    elsif user_type == 'manager'
      links = links.select{|l| l['type'] == 'org_manager' }
    elsif user_type == 'supervisor'
      links = links.select{|l| l['type'] == 'org_supervisor' }
    elsif user_type == 'premium_supervisor'
      links = links.select{|l| l['type'] == 'org_supervisor' && l['state']['premium'] }
    elsif user_type == 'eval'
      links = links.select{|l| l['type'] == 'org_user' && l['state']['eval'] }
    elsif user_type == 'subscription'
      links = links.select{|l| l['type'] == 'org_subscription' }
    elsif user_type == 'approved_user'
      links = links.select{|l| l['type'] == 'org_user' && !l['state']['pending'] }
    elsif user_type == 'sponsored_user'
      links = links.select{|l| l['type'] == 'org_user' && l['state']['sponsored'] }
    elsif user_type == 'all'
      links = links.select{|l| ['org_user', 'org_manager', 'org_supervisor'].include?(l['type']) }
    else
      raise "unrecognized type, #{user_type}"
    end
    user_ids = links.map{|l| l['user_id'] }.uniq
    User.where(:id => User.local_ids(user_ids))
  end
  
  def users
    self.attached_users('user')
  end
  
  def sponsored_users(chainable=true)
    # TODO: get rid of this double-lookup
    users = self.attached_users('user').select{|u| self.sponsored_user?(u) }
    if chainable
      User.where(:id => users.map(&:id))
    else
      users
    end
  end

  def eval_users(chainable=true)
    # TODO: get rid of this double-lookup
    users = self.attached_users('eval')
    if chainable
      User.where(:id => users.map(&:id))
    else
      users
    end
  end
  
  def approved_users(chainable=true)
    # TODO: get rid of this double-lookup
    users = self.attached_users('user').select{|u| !self.pending_user?(u) }
    if chainable
      User.where(:id => users.map(&:id))
    else
      users
    end
  end
  
  def managers
    self.attached_users('manager')
  end
  
  def evals
    self.attached_users('eval')
  end
  
  def supervisors
    self.attached_users('supervisor')
  end  

  def premium_supervisors
    self.attached_users('premium_supervisor')
  end  

  def subscriptions
    self.attached_users('subscription')
  end

  def self.find_by_saml_issuer(eid)
    return nil unless eid
    key = GoSecure.sha512(eid, 'external_auth_key')
    res = Organization.find_by(external_auth_key: key)
    res ||= Organization.find_by(external_auth_shortcut: GoSecure.sha512(eid, 'external_auth_shortcut'))
    res
  end

  def find_saml_user(external_id, email=nil)
    return nil unless external_id && self.settings['saml_metadata_url']
    codes = ["ext:#{GoSecure.sha512(external_id, 'external_auth_user_id')}"]
    codes << "ext:#{GoSecure.sha512(email, "external_alias_for_#{self.global_id}")}" if email
    links = UserLink.where(record_code: codes)
    auth_links = links.select{|l| l.data['type'] == 'saml_auth' && l.data['state']['org_id'] == self.global_id }
    alias_links = links.select{|l| l.data['type'] == 'saml_alias' && l.data['state']['org_id'] == self.global_id }
    return nil if auth_links.empty? && alias_links.empty?
    # TODO: sharding
    res = self.attached_users('all').where(id: auth_links.map(&:user_id)).first
    res ||= self.attached_users('all').where(id: alias_links.map(&:user_id)).first
    res
  end

  def find_saml_alias(uid, email)
    return nil unless uid || email
    return nil unless self.settings['saml_metadata_url']
    codes = []
    codes << "ext:#{GoSecure.sha512(uid, "external_alias_for_#{self.global_id}")}" if uid
    codes << "ext:#{GoSecure.sha512(email, "external_alias_for_#{self.global_id}")}" if email
    user_ids = UserLink.where(record_code: codes).select{|l| l.data['type'] == 'saml_alias' }.map(&:user_id)
    # if user_ids.empty?
    #   user_ids = UserLink.links_for()  
    # end
    return nil if user_ids.empty?
    # TODO: sharding
    self.attached_users('all').where(id: user_ids).first
  end

  def import_saml_users(csv_str)
    require 'csv'
    csv = CSV.parse(csv_str, headers: true)
    csv.each do |row|
      if row['email'] && row['role']
        role = 'communicator'
        if row['role'] = 'Staff'
          role = 'supporter'
        end
      end
    end
  end

  def link_saml_user(existing_user, data)
    return false unless existing_user
    return false unless self.settings['saml_metadata_url']
    return false unless data && data[:external_id]
    record_code = GoSecure.sha512(data[:external_id], 'external_auth_user_id')
    state = {
      'org_id' => self.global_id,
      'external_id' => data[:external_id],
      'email' => data[:email],
      'user_name' => data[:user_name],
      'roles' => data[:roles]
    }
    existing_user.settings['possibly_external_auth'] = true
    existing_user.save
    # TODO: sharding
    UserLink.where(record_code: "ext:#{record_code}").where(['user_id != ?', existing_user.id]).each do |link|
      # ensure auth is tied to only one user at a time
      if link.data['state']['org_id'] == self.global_id && link.data['type'] == 'saml_auth'
        link.destroy
      end
    end
    ul = UserLink.generate_external(existing_user, record_code, 'saml_auth', state)
    ul.save
    link_saml_alias(existing_user, data[:user_name], false) if data[:user_name]
    link_saml_alias(existing_user, data[:email], false) if data[:email]
    ul
  end

  def link_saml_alias(user, external_alias, clear_existing=true)
    return false unless user
    return false unless self.settings['saml_metadata_url']
    record_code = GoSecure.sha512(external_alias, "external_alias_for_#{self.global_id}")
    found = nil
    skip_add = false
    UserLink.links_for(user).select{|l| l['type'] == 'saml_alias' && l['state']['org_id'] == self.global_id }.each do |link|
      if link['record_code'] != "ext:#{record_code}"
        if clear_existing || external_alias.blank?
          UserLink.remove(user, link['record_code'], 'saml_alias') 
        else
          skip_add = true
        end
      else
      end
    end
    UserLink.where(record_code: "ext:#{record_code}").select do |link|
      if link.data['type'] == 'saml_alias' && link.data['state']['org_id'] == self.global_id
        if link.user == user
          found = link
        elsif clear_existing || external_alias.blank?
          link.destroy
        else
          skip_add = true
        end
      end
    end
    if external_alias.blank?
      return true
    elsif !found && !skip_add
      found = UserLink.generate_external(user, record_code, 'saml_alias', {'org_id' => self.global_id, 'alias' => external_alias})
      found.save
    end
    found
  end

  def self.unlink_saml_user(user, hashed_external_id)
    return false unless user && hashed_external_id
    record_code = hashed_external_id
    UserLink.remove(user, record_code, 'saml_auth')
    if UserLink.links_for(user).none?{|l| l['type'] == 'saml_auth' }
      user.settings.delete('possibly_external_auth')
      user.save
    end
    true
  end

  def self.external_auth_for(user, allow_unenforced=false)
    user = User.find_by_path(user) if user.is_a?(String)
    return nil unless user
    org = nil
#    return nil if !user.settings['possibly_external_auth']
    links = UserLink.links_for(user).select{|l| !l['state']['pending'] && ['org_user', 'org_supervisor', 'org_manager'].include?(l['type']) }.sort_by{|l| l['record_code'] }
    org_ids = []
    links.each do |link|
      # TODO: Sharding
      klass, global_id = link['record_code'].split(/:/)
      org_ids << User.local_ids([global_id])[0] if klass == 'Organization'
    end
    orgs = Organization.where(id: org_ids).where('external_auth_key IS NOT NULL').order('id ASC')
    orgs.detect{|o| o.settings['saml_metadata_url'] && (o.settings['saml_enforced'] || allow_unenforced) }
  end
  
  def self.attached_orgs(user, include_org=false)
    return [] unless user
    links = UserLink.links_for(user)
    org_ids = []
    alias_hash = {}
    auth_hash = {}
    links.each do |link|
      if link['type'] == 'org_user' || link['type'] == 'org_manager' || link['type'] == 'org_supervisor'
        org_ids << link['record_code'].split(/:/)[1]
      end
      if link['type'] == 'saml_alias'
        alias_hash[link['state']['org_id']] ||= []
        alias_hash[link['state']['org_id']] << link['state']['alias']
      end
      if link['type'] == 'saml_auth'
        auth_hash[link['state']['org_id']] = true
      end
    end
    res = []
    orgs = {}
    Organization.find_all_by_global_id(org_ids.uniq).each do |org|
      orgs[Webhook.get_record_code(org)] = org
    end
    links.each do |link|
      org = orgs[link['record_code']]
      if link['type'] == 'org_user' && org
        e = {
          'id' => org.global_id,
          'name' => org.settings['name'],
          'image_url' => org.settings['image_url'],
          'type' => 'user',
          'added' => link['state']['added'],
          'pending' => !!link['state']['pending'],
          'sponsored' => !!link['state']['sponsored']
        }
        e['profile'] = org.settings['communicator_profile'].slice('profile_id', 'template_id', 'frequency') if org.settings['communicator_profile']
        e['external_auth'] = true if org.settings['saml_metadata_url']
        e['external_auth_connected'] = true if e['external_auth'] && auth_hash[org.global_id]
        e['external_auth_alias'] = alias_hash[org.global_id].join(', ') if e['external_auth'] && alias_hash[org.global_id]
        e['login_timeout'] = org.settings['inactivity_timeout'] if org.settings['inactivity_timeout']
        e['premium'] = true if org.settings['org_access']
        e['org'] = org if include_org
        res << e
      elsif link['type'] == 'org_manager' && org
        e = {
          'id' => org.global_id,
          'name' => org.settings['name'],
          'image_url' => org.settings['image_url'],
          'type' => 'manager',
          'added' => link['state']['added'],
          'full_manager' => !!link['state']['full_manager'],
          'admin' => !!org.admin
        }
        e['external_auth'] = true if org.settings['saml_metadata_url']
        e['external_auth_connected'] = true if e['external_auth'] && auth_hash[org.global_id]
        e['external_auth_alias'] = alias_hash[org.global_id].join(', ') if e['external_auth'] && alias_hash[org.global_id]
        e['login_timeout'] = org.settings['inactivity_timeout'] if org.settings['inactivity_timeout']
        e['premium'] = true if org.settings['org_access']
        e['restricted'] = true if org.settings['org_access'] == false
        e['org'] = org if include_org
        res << e
      elsif link['type'] == 'org_supervisor' && org
        e = {
          'id' => org.global_id,
          'name' => org.settings['name'],
          'image_url' => org.settings['image_url'],
          'type' => 'supervisor',
          'added' => link['state']['added'],
          'pending' => !!link['state']['pending']
        }
        e['profile'] = org.settings['supervisor_profile'].slice('profile_id', 'template_id', 'frequency') if org.settings['supervisor_profile']
        e['external_auth'] = true if org.settings['saml_metadata_url']
        e['external_auth_connected'] = true if e['external_auth'] && auth_hash[org.global_id]
        e['external_auth_alias'] = alias_hash[org.global_id].join(', ') if e['external_auth'] && alias_hash[org.global_id]
        e['login_timeout'] = org.settings['inactivity_timeout'] if org.settings['inactivity_timeout']
        e['premium'] = true if org.settings['org_access']
        e['org'] = org if include_org
        res << e
      end
    end
    res
  end
  
  def user?(user)
    managed_user?(user)
  end

  def add_extras_to_user(user_key)
    user = User.find_by_path(user_key)
    raise "invalid user, #{user_key}" unless user
    valid = self.attached_users('all').detect{|u| u.global_id == user.global_id }
    raise "user not attached to org" unless valid
    total_extras = (self.settings || {})['total_extras'] || 0
    extras_count = self.extras_users.count
    raise "no extras available" if total_extras <= extras_count
    activated = (self.settings || {})['activated_extras'] || 0
    new_activation = false;
    if activated < total_extras
      new_activation = true
      self.settings['activated_extras'] = activated + 1
      self.save
    end
    User.purchase_extras({'premium_symbols' => true, 'user_id' => user.global_id, 'source' => 'org_added', 'org_id' => self.global_id, 'new_activation' => new_activation})
  end

  def extras_users
    self.attached_users('all').select{|u| u.extras_for_org?(self) }
  end
  
  def add_user(user_key, pending, sponsored=true, eval_account=false)
    user = User.find_by_path(user_key)
    raise "invalid user, #{user_key}" unless user
    raise "invalid settings" if eval_account && !sponsored
    # for_different_org ||= user.settings && user.settings['managed_by'] && (user.settings['managed_by'].keys - [self.global_id]).length > 0
    # raise "already associated with a different organization" if for_different_org
    if eval_account
      sponsored_eval_count = self.eval_users(false).count
      raise "no eval licenses available" if sponsored && ((self.settings || {})['total_eval_licenses'] || 0) <= sponsored_eval_count
    else
      sponsored_user_count = self.sponsored_users(false).count
      raise "no licenses available" if sponsored && ((self.settings || {})['total_licenses'] || 0) <= sponsored_user_count
    end
    user.update_subscription_organization(self, pending, sponsored, eval_account)
    true
  end
  
  def remove_user(user_key)
    user = User.find_by_path(user_key)
    raise "invalid user, #{user_key}" unless user
    pending = !!UserLink.links_for(user).detect{|l| l['type'] == 'org_user' && l['record_code'] == Webhook.get_record_code(self) && l['state']['pending'] }
    user.update_subscription_organization("r#{self.global_id}")
    notify('org_removed', {
      'user_id' => user.global_id,
      'user_type' => 'user',
      'removed_at' => Time.now.iso8601
    }) unless pending
    OrganizationUnit.schedule(:remove_as_member, user_key, 'communicator', self.global_id)
    self.remove_extras_from_user(user.user_name)
    true
  end

  def remove_extras_from_user(user_key)
    user = User.find_by_path(user_key)
    any_link = user && !!UserLink.links_for(user).detect{|l| (l['type'] == 'org_user' || l['type'] == 'org_supervisor') && l['record_code'] == Webhook.get_record_code(self)}
    if any_link
      User.deactivate_extras({'user_id' => user.global_id, 'org_id' => self.global_id, 'ignore_errors' => true})
      return true
    end
    false
  end

  def additional_listeners(type, args)
    if type == 'org_removed'
      u = User.find_by_global_id(args['user_id'])
      res = []
      res << u.record_code if u
      res
    end
  end
  
  def self.usage_stats(approved_users, admin=false)
    sessions = LogSession.where(['started_at > ?', 4.months.ago]).where({log_type: 'session'})
    res = {
      'weeks' => [],
      'user_counts' => {}
    }

    if !admin
      # TODO: sharding
      sessions = sessions.where(:user_id => approved_users.map(&:id))
    end

    res['user_counts']['goal_set'] = approved_users.select{|u| !!u.settings['primary_goal'] }.length
    two_weeks_ago_iso = 2.weeks.ago.iso8601
    res['user_counts']['goal_recently_logged'] = approved_users.select{|u| u.settings['primary_goal'] && u.settings['primary_goal']['last_tracked'] && u.settings['primary_goal']['last_tracked'] > two_weeks_ago_iso }.length
    
    recent = sessions.where(['started_at > ?', 2.weeks.ago])
    res['user_counts']['recent_session_count'] = recent.count
    res['user_counts']['recent_session_seconds'] = recent.sum('EXTRACT(epoch FROM (ended_at - started_at))')
    res['user_counts']['recent_session_hours'] = (res['user_counts']['recent_session_seconds'] / 3600.0).round(2)
    res['user_counts']['recent_session_user_count'] = recent.distinct.count('user_id')
    res['user_counts']['total_users'] = approved_users.count

    weekyears = []
    weekdate = 8.weeks.ago
    while weekdate <= Time.now
      weekyears << WeeklyStatsSummary.date_to_weekyear(weekdate)
      weekdate += 1.week
    end
    total_user_weeks = 0
    total_words = 0
    total_models = 0
    total_sessions = 0
    total_seconds = 0
    words = {}
    models = {}
    WeeklyStatsSummary.where(user_id: approved_users.map(&:id), weekyear: weekyears).each do |sum|
      total_user_weeks += 1
      next unless sum.data && sum.data['stats']
      total_sessions += sum.data['stats']['total_sessions'] || 0
      total_seconds += sum.data['stats']['total_session_seconds'] || 0
      (sum.data['stats']['all_word_counts'] || {}).each do |word, cnt|
        total_words += cnt
        words[word] ||= {user_ids: {}, cnt: 0}
        words[word][:cnt] += cnt
        words[word][:user_ids][sum.user_id] = true
      end
      (sum.data['stats']['modeled_word_counts'] || {}).each do |word, cnt|
        total_models += cnt
        models[word] ||= {user_ids: {}, cnt: 0}
        models[word][:cnt] += cnt
        models[word][:user_ids][sum.user_id] = true
      end
    end
    res['user_counts']['total_user_weeks'] = total_user_weeks
    res['user_counts']['total_words'] = total_words
    res['user_counts']['total_models'] = total_models
    res['user_counts']['total_sessions'] = total_sessions
    res['user_counts']['total_seconds'] = total_seconds
    res['user_counts']['total_user_weeks'] = total_user_weeks

    user_ids = approved_users.map(&:global_id)
    res['user_counts']['word_counts'] = words.to_a.sort_by{|w, h| [0 - h[:user_ids].length, 0 - h[:cnt], w] }.map{|w, h| {word: w, cnt: h[:cnt] * h[:user_ids].keys.length} }.select{|w| !w[:word].match(/^\+/) && w[:cnt] > user_ids.length }[0, 75]
    res['user_counts']['modeled_word_counts'] = models.to_a.sort_by{|w, h| [0 - h[:user_ids].length, 0 - h[:cnt], w] }.map{|w, h| {word: w, cnt: h[:cnt] * h[:user_ids].keys.length} }.select{|w| !w[:word].match(/^\+/) && w[:cnt] > user_ids.length }[0, 75]
    
    sessions.group("date_trunc('week', started_at)").select("date_trunc('week', started_at)", "SUM(EXTRACT(epoch FROM (ended_at - started_at)))", "COUNT(*)").sort_by{|s| s.date_trunc }.each do |s|
      date = s.date_trunc
      count = s.count
      sum = s.sum
      if date && date < Time.now
        res['weeks'] << {
          'timestamp' => date.to_time.to_i,
          'session_seconds' => sum,
          'sessions' => count
        }
      end
    end
    res
  end

  def self.load_domains(force=false)
    domains = JSON.parse(RedisInit.default.get('domain_org_ids')) rescue nil
    if !domains || force
      domains = {}
      Organization.where(custom_domain: true).order('id ASC').each do |org|
        (org.settings['hosts'] || []).each do |host|
          if !domains[host]
            domains[host] = org.settings['host_settings'] || {}
            domains[host]['org_id'] = org.global_id
          end
        end
      end
      Permissions.setex(RedisInit.default, 'domain_org_ids', 72.hours.from_now.to_i, domains.to_json)
    end
    domains
  end

  def matches_profile_id(type, profile_id, profile_template_id)
    id = (self.settings["#{type}_profile"] || {})['profile_id']
    id ||= 'default'
    return nil if id == 'none' || id == 'blank'
    if id == 'default'
      return profile_id == ProfileTemplate.default_profile_id(type)
    elsif profile_template_id && (self.settings["#{type}_profile"] || {})['template_id']
      return profile_template_id == (self.settings["#{type}_profile"] || {})['template_id']
    else
      return id == profile_id
    end
  end

  def profile_frequency(type)
    seconds = (self.settings["#{type}_profile"] || {})["frequency"]
    seconds ||= 12.months.to_i
    seconds
  end

  def assert_profile(profile_type)
    profile_type += "_profile" unless profile_type.match(/_profile/)
    template_id = (self.settings[profile_type] || {})['template_id']
    id = (self.settings[profile_type] || {})['profile_id']
    return if !id || id == 'none'
    template = ProfileTemplate.find_by_code(template_id || id)
    users = []
    if profile_type == 'supervisor_profile'
      users = self.attached_users('supervisor')
    elsif profile_type == 'communicator_profile'
      users = self.attached_users('approved_user')
    end
    users.each do |user|
      ue = UserExtra.find_or_create_by(user: user)
      if id
        ue.process_profile(id, template && template.global_id, self)
      end
    end
  end
  
  def process_params(params, non_user_params)
    self.settings ||= {}
    self.settings['name'] = process_string(params['name']) if params['name']
    self.settings['premium'] = process_boolean(params['premium']) if params['premium'] != nil
    self.settings['org_access'] = process_boolean(params['org_access']) if params['premium'] != nil
    self.settings['inactivity_timeout'] = params['inactivity_timeout'].to_i if params['inactivity_timeout']
    self.settings.delete('inactivity_timeout') if (self.settings['inactivity_timeout'] || 0) < 10
    self.settings['image_url'] = process_string(params['image_url']) if params['image_url']
    raise "updater required" unless non_user_params['updater']
    if params[:allotted_licenses]
      total = params[:allotted_licenses].to_i
      used = self.sponsored_users(false).count
      if total < used
        add_processing_error("too few licenses, remove some users first")
        return false
      end
      if self.settings['total_licenses'] != total
        self.settings['total_licenses'] = total
        self.log_purchase_event({
          'type' => 'update_license_count',
          'count' => total,
          'updater_id' => non_user_params['updater'].global_id,
          'updater_user_name' => non_user_params['updater'].user_name
        }, false)
      end
    end
    if params[:external_auth_shortcut]
      if params[:external_auth_shortcut].length < 5
        add_processing_error("auth shortcut too short")
        return false
      end
      key = GoSecure.sha512(params[:external_auth_shortcut], 'external_auth_shortcut')
      current = Organization.find_by(external_auth_shortcut: key)
      if !current || current.id == self.id
        self.settings['external_auth_shortcut'] = params[:external_auth_shortcut]
        self.external_auth_shortcut = key
      else
        add_processing_error("auth shortcut #{params[:external_auth_shortcut]} is already taken")
        return false
      end
    end
    if params[:allotted_supervisor_licenses]
      total = params[:allotted_supervisor_licenses].to_i
      used = self.premium_supervisors.count
      if total < used
        add_processing_error("too few licenses, remove some users first")
        return false
      end
      if self.settings['total_supervisor_licenses'] != total
        self.settings['total_supervisor_licenses'] = total
        self.log_purchase_event({
          'type' => 'update_supervisor_license_count',
          'count' => total,
          'updater_id' => non_user_params['updater'].global_id,
          'updater_user_name' => non_user_params['updater'].user_name
        }, false)
      end
    end
    if params[:allotted_eval_licenses]
      total = params[:allotted_eval_licenses].to_i
      used = self.eval_users(false).count
      if total < used
        add_processing_error("too few eval licenses, remove some users first")
        return false
      end
      if self.settings['total_eval_licenses'] != total
        self.settings['total_eval_licenses'] = total
        self.log_purchase_event({
          'type' => 'update_eval_license_count',
          'count' => total,
          'updater_id' => non_user_params['updater'].global_id,
          'updater_user_name' => non_user_params['updater'].user_name
        }, false)
      end
    end
    if params[:allotted_extras]
      total = params[:allotted_extras].to_i
      used = self.extras_users.count
      if total < used
        add_processing_error("too few extras (premium symbols), remove some users first")
        return false
      end
      if self.settings['total_extras'] != total
        self.settings['total_extras'] = total
        self.log_purchase_event({
          'type' => 'update_extras_count',
          'count' => total,
          'updater_id' => non_user_params['updater'].global_id,
          'updater_user_name' => non_user_params['updater'].user_name
        }, false)
      end
    end
    if !params[:licenses_expire].blank?
      time = Time.parse(params[:licenses_expire])
      self.settings['licenses_expire'] = time.iso8601
    end
    self.settings['saml_metadata_url'] = params['saml_metadata_url']
    self.settings['saml_sso_url'] = params['saml_sso_url']
    self.settings['saml_enforced'] = params['saml_sso_url']

    if params[:host_settings]
      self.settings['host_settings'] ||= {}
      self.settings['host_settings']['css'] = params[:host_settings]['css_url']
      self.settings['host_settings']['app_name'] = params[:host_settings]['app_name'].blank?  ? "CoughDrop" : params[:host_settings]['app_name']
      self.settings['host_settings']['company_name'] = params[:host_settings]['company_name'].blank? ? "CoughDrop" : params[:host_settings]['company_name']
      ['ios_store_url', 'play_store_url', 'kindle_store_url', 'windows_32_bit_url', 'windows_64_bit_url',
                'blog_url', 'twitter_url', 'twitter_handle', 'facebook_url', 'youtube_url',
                'support_url', 'logo_url', 'css_url', 'admin_email', 'board_user_name'].each do |str|
                
        if params[:host_settings][str] != nil
          val = process_string(params[:host_settings][str])
          self.settings['host_settings'][str] = val
          self.settings['host_settings'].delete(str) if val.blank?
        end
      end
      if self.settings['host_settings']['twitter_handle']
        self.settings['host_settings']['twitter_handle'] = self.settings['host_settings']['twitter_handle'].sub(/^\@/, '')
      end
    end

    ['communicator_profile', 'supervisor_profile'].each do |prof|
      prof_id = prof + "_id"
      do_assert = false
      opts = {'profile_id' => params[prof_id]}
      if params[prof + "_frequency"].to_i > 0
        do_assert = (self.settings[prof] || {})['frequency'] != params[prof + "_frequency"].to_i
        opts['frequency'] = params[prof + "_frequency"].to_f 
        opts['frequency'] *= 1.month.to_i if opts['frequency'] < 300
      end
      if params[prof_id] && (self.settings[prof] || {})['profile_id'] != params[prof_id]
        valid = false
        if params[prof_id] == 'default' || params[prof_id] == 'none'
          valid = true
          opts = nil if params[prof_id] == 'none'
        else
          pt = ProfileTemplate.find_by_code(params[prof_id])
          if pt
            if pt.settings['public'] == false && pt.organization != self
              add_processing_error("#{prof_id} not authorized for this organization")
              return false
            end
            opts['template_id'] = pt.global_id
            valid = true
          end
        end
        if valid
          do_assert = true
        else
          add_processing_error("#{prof_id} is not valid")
          return false
        end
      end
      if do_assert
        self.settings[prof] = opts
        self.schedule(:assert_profile, prof)
      end
    end
    
    if params[:home_board_key]
      key = params[:home_board_key]
      if key.match(/^https?:\/\/[^\/]+\//)
        key = key.sub(/^https?:\/\/[^\/]+\//, '')
      end
    
      board = Board.find_by_path(key)
      if board && board.public
        self.settings['default_home_board'] = {
          'id' => board.global_id,
          'key' => board.key
        }
      elsif board
        management_ids = self.managers.map(&:global_id) + self.supervisors.map(&:global_id)
        # if any of the managers or supervisors own the board, then it's ok
        if management_ids.include?(board.user.global_id)
          self.settings['default_home_board'] = {
            'id' => board.global_id,
            'key' => board.key
          }
        end
      end
    end
    
    if params[:management_action]
      if !self.id
        add_processing_error("can't manage users on create") 
        return false
      end

      action, key = params[:management_action].split(/-/, 2)
      begin
        if action == 'add_user'
          self.add_user(key, true, true, false)
        elsif action == 'add_unsponsored_user' || action == 'add_external_user'
          self.add_user(key, true, false, false)
        elsif action == 'add_eval'
          self.add_user(key, true, true, true)
        elsif action == 'add_supervisor'
          self.add_supervisor(key, true)
        elsif action == 'add_premium_supervisor'
          self.add_supervisor(key, true, true)
        elsif action == 'add_assistant' || action == 'add_manager'
          self.add_manager(key, action == 'add_manager')
        elsif action == 'add_extras'
          self.add_extras_to_user(key)
        elsif action == 'remove_user'
          self.remove_user(key)
        elsif action == 'remove_supervisor'
          self.remove_supervisor(key)
        elsif action == 'remove_assistant' || action == 'remove_manager'
          self.remove_manager(key)
        elsif action == 'remove_extras'
          self.remove_extras_from_user(key)
        end
      rescue => e
        add_processing_error("user management action failed: #{e.message}")
        return false
      end
    end
    @processed = true
    true
  end
end
