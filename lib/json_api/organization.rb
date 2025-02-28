module JsonApi::Organization
  extend JsonApi::Json
  
  TYPE_KEY = 'organization'
  DEFAULT_PAGE = 15
  MAX_PAGE = 25

  def self.build_json(org, args={})
    json = {}
    json['id'] = org.global_id
    json['name'] = org.settings['name']
    json['admin'] = !!org.admin
    json['premium'] = org.settings['premium'] || json['admin']
    
    if args.key?(:permissions)
      json['permissions'] = org.permissions_for(args[:permissions])
    end
    
    if json['permissions'] && json['permissions']['edit']
      json['custom_domain'] = !!org.custom_domain
      if json['custom_domain']
        json['hosts'] = org.settings['hosts'] || []
        json['host_settings'] = org.settings['host_settings'] || {}
      end
      json['saml_metadata_url'] = org.settings['saml_metadata_url']
      json['saml_sso_url'] = org.settings['saml_sso_url']

      json['allotted_licenses'] = org.settings['total_licenses'] || 0
      json['image_url'] = org.settings['image_url']
      json['org_access'] = org.settings['org_access']
      json['org_access'] = true if json['org_access'] == nil
      json['allotted_eval_licenses'] = org.settings['total_eval_licenses'] || 0
      json['allotted_supervisor_licenses'] = org.settings['total_supervisor_licenses'] || 0
      json['allotted_extras'] = org.settings['total_extras'] || 0
      json['used_licenses'] = 0
      json['used_evals'] = 0
      json['used_supervisors'] = 0
      json['total_users'] = 0
      json['total_managers'] = 0
      json['total_premium_supervisors'] = 0
      json['total_supervisors'] = 0
      json['used_extras'] = org.extras_users.count || 0
      json['include_extras'] = org.settings['include_extras']
      json['supervisor_profile_id'] = (org.settings['supervisor_profile'] || {})['profile_id'] || 'default'
      if json['supervisor_profile_id'] == 'default'
        json['supervisor_profile_id'] = ProfileTemplate.default_profile_id('supervisor')
      end
      json['supervisor_profile_frequency'] = (((org.settings['supervisor_profile'] || {})['frequency'] || 12.months.to_i).to_f / 1.month.to_f).round(2)
      json['communicator_profile_id'] = (org.settings['communicator_profile'] || {})['profile_id'] || 'default'
      if json['communicator_profile_id'] == 'default'
        json['communicator_profile_id'] = ProfileTemplate.default_profile_id('communicator')
      end
      json['communicator_profile_frequency'] = (((org.settings['communicator_profile'] || {})['frequency'] || 12.months.to_i).to_f / 1.month.to_f).round(2)
      user_ids = []
      UserLink.links_for(org).each do |link|
        if link['type'] == 'org_manager'
          json['total_managers'] += 1
        elsif link['type'] == 'org_supervisor'
          json['total_supervisors'] += 1
          if link['state']['premium']
            json['total_premium_supervisors'] += 1 
            json['used_supervisors'] += 1
          end
        elsif link['type'] == 'org_user'
          user_ids << link['user_id']
          json['total_users'] += 1
          json['used_evals'] += 1 if link['state']['eval']
          json['used_licenses'] += 1 if link['state']['sponsored'] && !link['state']['eval']
        end
      end

      json['licenses_expire'] = org.settings['licenses_expire'] if org.settings['licenses_expire']
      json['created'] = org.created_at.iso8601
      json['children_orgs'] = org.children_orgs.map do |org|
        {
          'id' => org.global_id,
          'name' => org.settings['name']
        }
      end
    end
    if json['permissions'] && json['permissions']['edit']
      json['org_subscriptions'] = org.subscriptions.map{|u| JsonApi::User.as_json(u, limited_identity: true, subscription: true) }
    end
    if json['permissions'] && json['permissions']['view']
      json['default_home_board'] = org.settings['default_home_board']
      json['home_board_key'] = org.settings['default_home_board'] && org.settings['default_home_board']['key']
    end
    if json['permissions'] && json['permissions']['manage_subscription']
      json['purchase_history'] = org.purchase_history
    end
    
    json
  end
end
