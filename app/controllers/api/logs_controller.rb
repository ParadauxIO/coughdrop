class Api::LogsController < ApplicationController
  before_action :require_api_token, :except => [:lam, :trends]
  
  def logging_code_for(user)
    request.headers["HTTP_X_LOGGING_CODE_FOR_#{user.global_id}"] || request.headers["X-Logging-Code-For-#{user.global_id}"]
  end

  def index
    user = User.find_by_path(params['user_id'])
    return unless allowed?(user, 'supervise')
    if user.modeling_only?
      return unless allowed?(user, 'never_allow')
    elsif user.private_logging? && (@true_user || @api_user) != user
      return unless allowed?(user, 'never_allow')
    end

    user_id_cutoffs = {}
    user_ids = [user.id]
    for_self = true
    user_ids = [] if params['supervisees']
    if params['supervisees']
      sups = user.supervisees.select{|u| !u.private_logging? }
      sups.each do |sup|
        user_ids << sup.id
        cutoff = sup.logging_cutoff_for(@api_user, logging_code_for(sup))
        user_id_cutoffs[sup.id] = cutoff if cutoff
      end
      for_self = false
    else
      cutoff = user.logging_cutoff_for(@api_user, logging_code_for(user))
      if cutoff
        user_id_cutoffs[user.id] = cutoff
      end
    end
    
    options = {:start => params['start'], :end => params['end']}
    Stats.sanitize_find_options!(options)
    logs = LogSession.where({:user_id => user_ids}).where.not({:started_at => nil})
    if user_id_cutoffs.keys.length > 0
      # limit results for cutoffs
      query_string = ""
      query_params = []
      user_ids.each do |id, cutoff|
        cutoff = user_id_cutoffs[id]
        query_string += " OR " if query_string.length > 0
        if cutoff == 0
          query_string += "(user_id != ?)"
          query_params << id
        elsif cutoff
          query_string += "(user_id = ? AND started_at > ?)"
          query_params << id
          query_params << cutoff.hours.ago
        else
          query_string += "(user_id = ?)"
          query_params << id
        end
      end
      query_params = [query_string] + query_params
      logs = logs.where(query_params)
    end
    params['type'] ||= 'all'
    if params['type'] == 'journal'
      return unless allowed?(user, 'delete')
    end
    if params['type'] != 'all' && ['session', 'note', 'assessment', 'eval', 'profile', 'journal'].include?(params['type'])
      logs = logs.where(:log_type => params['type'])
    else
      logs = logs.where(:log_type => ['session', 'note', 'assessment', 'eval', 'profile'])
    end
    if for_self && user.supporter_role?
      logs = logs.where(:log_type => ['profile', 'note', 'eval'])
    end
    if params['highlighted']
      logs = logs.where(:highlighted => true)
    end
    if params['goal_id']
      goal = UserGoal.find_by_global_id(params['goal_id'])
      if goal && goal.user == user
        logs = logs.where(:user_id => user.id, :goal_id => goal.id)
      else
        logs = logs.where(:id => 0)
      end
    end
    if params['location_id']
      location = ClusterLocation.find_by_global_id(params['location_id'])
      if location
        if location.cluster_type == 'geo'
          logs = logs.where(:geo_cluster_id => location.id)
        else
          logs = logs.where(:ip_cluster_id => location.id)
        end
      else
        logs = logs.where(:id => 0)
      end
    end
    if params['device_id']
      device = Device.find_by_global_id(params['device_id'])
      if device
        logs = logs.where(:device_id => device.id)
      else
        logs = logs.where(:id => 0)
      end
    end
    if params['start']
      logs = logs.where(['started_at > ?', options[:start_at]])
    end
    if params['end']
      logs = logs.where(['ended_at < ?', options[:end_at]])
    end
    logs = logs.order('started_at DESC, id')
    json = JsonApi::Log.paginate(params, logs)
    if user_id_cutoffs.keys.length > 0
      json[:meta]['logging_cutoffs'] = true 
      json[:meta]['logging_cutoff_min'] = user_id_cutoffs.values.compact.min
    end
    render json: json
  end

  def code_check
    user = User.find_by_path(params['user_id'])
    return unless exists?(user, params['user_id'])
    return unless allowed?(user, 'supervise')
    if user.private_logging? && (@true_user || @api_user) != user
      return unless allowed?(user, 'never_allow')
    end
    matches = user.settings['preferences']['logging_code'] && params['code'] == user.settings['preferences']['logging_code']
    render json: {valid: !!matches}
  end
  
  def show
    log = LogSession.find_by_global_id(params['id'])
    return unless exists?(log, params['id'])
    user = log && log.user
    return unless allowed?(user, 'supervise')
    if user.private_logging? && (@true_user || @api_user) != user
      return unless allowed?(user, 'never_allow')
    end
    cutoff = user.logging_cutoff_for(@api_user, logging_code_for(user))
    if cutoff && log.started_at < cutoff.hours.ago
      return unless allowed?(user, 'never_allow')
    end
    render json: JsonApi::Log.as_json(log, :wrapper => true, :permissions => @api_user, :encryption_allowed => (request.headers["X-SUPPORTS-REMOTE-ENCRYPTION"] == 'true')).to_json
  end

  def create
    ip = request.env["HTTP_X_FORWARDED_FOR"] || request.remote_ip
    user_id = params['user_id'] || (params['log'] && params['log']['user_id'])
    user = user_id ? User.find_by_path(user_id) : @api_user
    return unless allowed?(user, 'model')
    
    log = LogSession.process_as_follow_on(params['log'].to_unsafe_h, {
      :author => @api_user,
      :ip_address => ip,
      :user => user,
      :device => Device.find_by_global_id(@api_device_id),
      :request_id => request.request_id
    })
    if !log || log.errored?
      api_error(400, {error: "log creation failed", errors: log && log.processing_errors})
    else
      render json: JsonApi::Log.as_json(log, :wrapper => true).to_json
    end
  end
  
  def import
    user = User.find_by_path(params['user_id'])
    return unless exists?(user, params['user_id'])
    return unless allowed?(user, 'supervise')
    if params['url'] || params['content']
      type = 'unspecified'
      type = 'obl' if params['type'] == 'obl'
      type = 'lam' if params['type'] == 'lam'
      progress = Progress.schedule(Exporter, :process_log, params['url'] || params['content'], type, user.global_id, @api_user.global_id, @api_device_id)
      render json: JsonApi::Progress.as_json(progress, :wrapper => true).to_json
    else
      remote_path = "imports/logs/#{@api_user.global_id}/upload-#{GoSecure.nonce('filename')}.txt"
      content_type = "text/plain"
      upload_params = Uploader.remote_upload_params(remote_path, content_type)
      url = upload_params[:upload_url] + remote_path
      upload_params[:success_url] = "/api/v1/logs/import?user_id=#{params['user_id']}&type=#{params['type']}&url=#{CGI.escape(url)}"
      render json: {'remote_upload' => upload_params}.to_json
    end
  end

  def update
    log = LogSession.find_by_global_id(params['id'])
    user = log && log.user
    return unless exists?(log, params['id'])
    return unless allowed?(user, 'supervise')
    if user.private_logging? && (@true_user || @api_user) != user
      return unless allowed?(user, 'never_allow')
    end
    cutoff = user.logging_cutoff_for(@api_user, logging_code_for(user))
    if cutoff && log.started_at < cutoff.hours.ago
      return unless allowed?(user, 'never_allow')
    end    
    
    log.process(params['log'], {
      :author => @api_user,
      :user => user,
      :device => Device.find_by_global_id(@api_device_id),
      :update_only => true
    })
    
    render json: JsonApi::Log.as_json(log, :wrapper => true).to_json
  end
  
  def lam
    log = LogSession.find_by_global_id(params['log_id'])
    if !log || (log.data['nonce'] != params['nonce'])
      render plain: "Not found"
    else
      render plain: Stats.lam([log])
    end
  end
  
  def obl
    if params['log_id']
      log = LogSession.find_by_global_id(params['log_id'])
      return unless exists?(log, params['log_id'])
      return unless exists?(log.user)
      return unless allowed?(log.user, 'supervise')
      if log.user.private_logging? && (@true_user || @api_user) != log.user
        return unless allowed?(log.user, 'never_allow')
      end
      cutoff = log.user.logging_cutoff_for(@api_user, logging_code_for(log.user))
      if cutoff && log.started_at < cutoff.hours.ago
        return unless allowed?(log.user, 'never_allow')
      end    
  
      progress = Progress.schedule(Exporter, :export_log, log.global_id)
      render json: JsonApi::Progress.as_json(progress, :wrapper => true).to_json
    elsif params['user_id']
      user = User.find_by_global_id(params['user_id'])
      return unless exists?(user, params['user_id'])
      return unless allowed?(user, 'supervise')
      if user.private_logging? && (@true_user || @api_user) != user
        return unless allowed?(user, 'never_allow')
      end
      cutoff = user.logging_cutoff_for(@api_user, logging_code_for(user))
      if cutoff
        return unless allowed?(user, 'never_allow')
      end    
      progress = Progress.schedule(Exporter, :export_logs, user.global_id, !!params['anonymized'])
      render json: JsonApi::Progress.as_json(progress, :wrapper => true).to_json
    end
  end
  
  def trends
    extra_data = !!(@api_user && @api_user.allows?(@api_user, 'admin_support_actions'))
    res = JSON.parse(Permissable.permissions_redis.get('global/stats/trends')) rescue nil
    if !res #|| extra_data
      progress = Progress.schedule(WeeklyStatsSummary, :trends)
      res = JsonApi::Progress.as_json(progress, :wrapper => true)
    end
    if !extra_data
      res.delete(:admin) 
      res.delete('admin') 
    end
    
    render json: res
  end
  
end
