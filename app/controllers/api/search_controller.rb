require 'mime/types'
class Api::SearchController < ApplicationController
  before_action :require_api_token, :except => [:audio, :focuses]
  def symbols
    token = ENV['OPENSYMBOLS_TOKEN']
    protected_source = nil
    if params['q'].match(/premium_repo:pcs$/) 
      user_allowed = @api_user && @api_user.subscription_hash['extras_enabled']
      if !user_allowed && @api_user && params['user_name']
        ref_user = User.find_by_path(params['user_name'])
        user_allowed = ref_user && ref_user.allows?(@api_user, 'edit') && ref_user.subscription_hash['extras_enabled']
      end
      if user_allowed
        params['q'].sub!(/premium_repo:pcs$/, 'repo:pcs')
        # TODO: for now, don't combine them in non-protected searches even though it's coming
        # from the same source, otherwise things can get confusing
        token += ":pcs"
        protected_source = 'pcs'
      else
        return api_error 400, {error: 'premium search not allowed'}
      end
    elsif params['q'].match(/premium_repo:symbolstix$/) 
      user_allowed = @api_user && @api_user.subscription_hash['extras_enabled']
      if !user_allowed && @api_user && params['user_name']
        ref_user = User.find_by_path(params['user_name'])
        user_allowed = ref_user && ref_user.allows?(@api_user, 'edit') && ref_user.subscription_hash['extras_enabled']
      end
      if user_allowed
        params['q'].sub!(/premium_repo:symbolstix$/, 'repo:symbolstix')
        # TODO: for now, don't combine them in non-protected searches even though it's coming
        # from the same source, otherwise things can get confusing
        token += ":symbolstix"
        protected_source = 'symbolstix'
      else
        return api_error 400, {error: 'premium search not allowed'}
      end
    end
    locale = (params['locale'] || 'en').split(/-|_/)[0]
    safe = params['safe'] != '0'
    res = Typhoeus.get("https://www.opensymbols.org/api/v1/symbols/search?q=#{CGI.escape(params['q'])}&search_token=#{token}&locale=#{locale}&safe=#{safe ? '1' : '0'}", :timeout => 5, :ssl_verifypeer => false)
    # TODO: include locale in search
    results = JSON.parse(res.body) rescue nil
    results ||= []
    results.each do |result|
      type = MIME::Types.type_for(result['extension'])[0]
      result['content_type'] = type.content_type
      result['thumbnail_url'] ||= result['image_url']
      if protected_source
        result['protected'] = true 
        result['protected_source'] = protected_source
      end
    end
    if results.empty? && params['q'] && RedisInit.default
      RedisInit.default.hincrby('missing_symbols', params['q'].to_s, 1)
    end
    render json: results.to_json
  end

  def protected_symbols
    res = false
    ref_user = @api_user
    if params['library'] != 'giphy_asl' && params['user_name'] && params['user_name'] != ''
      maybe_ref_user = User.find_by_path(params['user_name'])
      return unless exists?(maybe_ref_user, params['user_name'])
      if maybe_ref_user.allows?(@api_user, 'edit')
        ref_user = maybe_ref_user
      end
    end
    if params['library']
      res = Uploader.find_images(params['q'], params['library'], 'en', ref_user, @api_user)
    end
    if res == false
      return allowed?(@api_user, 'never_allowed')
    end

    formatted = []
    res.each do |item|
      formatted << {
        'image_url' => item['url'],
        'thumbnail_url' => item['thumbnail_url'] || item['url'],
        'content_type' => item['content_type'],
        'name' => item['name'],
        'width' => item['width'],
        'height' => item['height'],
        'external_id' => item['external_id'],
        'finding_user_name' => @api_user.user_name,
        'protected' => !!item['protected'],
        'protected_source' => params['library'],
        'public' => false,
        'license' => item['license']['type'],
        'author' => item['license']['author_name'],
        'author_url' => item['license']['author_url'],
        'source_url' => item['license']['source_url'],
        'copyright_notice_url' => item['license']['copyright_notice_url']
      }
    end
    render json: formatted.to_json
  end
  
  def external_resources
    ref_user = @api_user
    if params['user_name'] && params['user_name'] != ''
      ref_user = User.find_by_path(params['user_name'])
      return unless exists?(ref_user, params['user_name'])
      return unless allowed?(ref_user, 'edit')
    end
    res = Uploader.find_resources(params['q'], params['source'], ref_user)
    render json: res.to_json
  end

  def focuses
    req = Typhoeus.get("https://workshop.openaac.org/api/v1/search/focus?locale=#{CGI.escape(params['locale'] || 'en')}&q=#{CGI.escape(params['q'] || '')}&category=#{CGI.escape(params['category'] || '')}&type=#{CGI.escape(params['type'] || '')}&sort=#{CGI.escape(params['sort'] || '')}", timeout: 10)
    json = JSON.parse(req.body) rescue nil
    render json: req.body
  end
    
  def parts_of_speech
    data = WordData.find_word(params['q'])
    res = {}
    if !data && params['suggestions']
      str = "#{params['q']}-not_defined"
      RedisInit.default.hincrby('overridden_parts_of_speech', str, 1) if RedisInit.default
      return api_error 404, {error: 'word not found'} unless data
    end
    
    if params['suggestions']
      res['recent_usage'] = WeeklyStatsSummary.word_trends(params['q'])
    end
    
    if params['suggestions'] && (data['sentences'] || []).length == 0
      str = "#{params['q']}-no_sentences"
      RedisInit.default.hincrby('overridden_parts_of_speech', str, 1) if RedisInit.default
    end

    render json: res.merge(data || {}).to_json
  end
  
  def proxy
    # TODO: must be escaped to correctly handle URLs like 
    # "https://opensymbols.s3.amazonaws.com/libraries/arasaac/to be reflected.png"
    # but it must also work for already-escaped URLs like
    # "http://www.stephaniequinn.com/Music/Commercial%2520DEMO%2520-%252013.mp3"
    uri = URI.parse(params['url']) rescue nil
    Rails.logger.warn("proxying #{params['url']}")
    uri ||= URI.parse(URI.escape(params['url']))
    # TODO: add timeout for slow requests
    request = Typhoeus::Request.new(uri.to_s, followlocation: true)
    begin
      content_type, body = get_url_in_chunks(request)
      if content_type == 'redirect'
        uri = URI.parse(body)
        request = Typhoeus::Request.new(uri.to_s, followlocation: true)
        content_type, body = get_url_in_chunks(request)
      end
    rescue BadFileError => e
      error = e.message
    end
    
    if !error
      str = "data:" + content_type
      str += ";base64," + Base64.strict_encode64(body)
      render json: {content_type: content_type, data: str}.to_json
    else
      api_error 400, {error: error}
    end
  end
  
  def apps
    res = AppSearcher.find(params['q'], params['os'])
    render json: res.to_json
  end
  
  def audio
    req = nil
    if params['locale'] && params['locale'].match(/^ga/)
      req = Typhoeus.post("https://abair.ie/aac_irish", body: {text: params['text'], voice: params['voice_id'] || 'Ulster'}, timeout: 5)
      if req.success?
        # src = Nokogiri(req.body).css('audio source')[0]['src']
        # req = Typhoeus.get("https://abair.ie#{src}")
      else
        raise req.body.to_json
        return api_error 400, {error: 'endpoint failed to respond'}
        req = nil
      end
    # elsif params['locale'] && params['locale'].match(/^uk/)
    #   req = Typhoeus.post("https://hf.space/gradioiframe/robinhad/ukrainian-tts/+/api/predict/", body: {data: [params['text'], "uk/mai/vits-tts"]}.to_json, headers: {'Content-Type': 'application/json'})
    #   json = JSON.parse(req.body) rescue nil
    #   req = nil
    #   if json
    #     req = nil
    #     pre, data = json['data'][0].split(/,/)
    #     type = pre.match(/data:([^;]+);/)[1]
    #     if data && type
    #       bytes = Base64.decode64(data)
    #       req = OpenStruct.new(body: bytes, headers: {'Content-Type' => type})
    #     end
    #   end
    elsif ENV['GOOGLE_TTS_TOKEN']
      # TODO: API for getting a list of all available remote languages
      cache = RedisInit.permissions.get("google/voices/#{params['locale']}")
      if cache
        json = JSON.parse(cache) rescue nil
      end
      if !json
        req = Typhoeus.get("https://texttospeech.googleapis.com/v1beta1/voices?languageCode=#{CGI.escape(params['locale'])}&key=#{ENV['GOOGLE_TTS_TOKEN']}")
        json = JSON.parse(req.body) rescue nil
      end
      req = nil
      if json && !cache
        Permissions.setex(RedisInit.permissions, "google/voices/#{params['locale']}", 72.hours.to_i, json.to_json)
      end
      if json && json['voices'] && json['voices'][0]
        gender = params['voice_id'] if ['male', 'female'].include?(params['voice_id'])
        voice = json['voices'].detect{|v| v['ssmlGender'] && v['ssmlGender'].upcase == params['voice_id'].upcase }
        voice ||= json['voices'][0]
        # https://cloud.google.com/text-to-speech/?hl=en_US&_ga=2.240949507.-1294930961.1646091692
        res = Typhoeus.post("https://texttospeech.googleapis.com/v1beta1/text:synthesize?key=#{ENV['GOOGLE_TTS_TOKEN']}", body: 
          {
            audioConfig: {audioEncoding: 'LINEAR16', pitch: 0, speakingRate: 1},
            input: {text: params['text']},
            voice: {languageCode: params['locale'], name: voice['name']}
          }.to_json, headers: {'Content-Type': 'application/json'}
        )
        json = JSON.parse(res.body) rescue nil
        if json && json['audioContent']
          bytes = Base64.decode64(json['audioContent'])
          req = OpenStruct.new(body: bytes, headers: {'Content-Type' => 'audio/wav'})
        end
      end
    else
      req = Typhoeus.get("http://translate.google.com/translate_tts?id=UTF-8&tl=#{params['locale'] || 'en'}&q=#{URI.escape(params['text'] || "")}&total=1&idx=0&textlen=#{(params['text'] || '').length}&client=tw-ob", timeout: 5, headers: {'Referer' => "https://translate.google.com/", 'User-Agent' => "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_12_4) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/58.0.3029.110 Safari/537.36"})
    end
    return api_error 400, {error: 'remote request failed'} unless req
    response.headers['Content-Type'] = req.headers['Content-Type']
    send_data req.body, :type => req.headers['Content-Type'], :disposition => 'inline'
  end
  
  def get_url_in_chunks(request)
    content_type = nil
    body = ""
    so_far = 0
    done = false
    request.on_headers do |response|
      # Some services (ahem, flickr) are returning a Location header, along with the response body
      if response.headers['Location'] && (response.code >= 300 || (response.headers['Content-Length'] && response.headers['Content-Length'].to_i <= response.headers['Location'].length))
        return ['redirect', URI.escape(response.headers['Location'])]
      end
      if response.success? || response.code == 200
        # TODO: limit to accepted file types
        content_type = response.headers['Content-Type']
        if !content_type.match(/^image/) && !content_type.match(/^audio/) && !content_type.match(/text\/json/)
          raise BadFileError, "Invalid file type, #{content_type}"
        end
      else
        raise BadFileError, "File not retrieved, status #{response.code}"
      end
    end
    request.on_body do |chunk|
      so_far += chunk.size
      if so_far < Uploader::CONTENT_LENGTH_RANGE
        body += chunk
      else
        raise BadFileError, "File too big (> #{Uploader::CONTENT_LENGTH_RANGE})"
      end
    end
    request.on_complete do |response|
      if !response.success? && response.code != 200
        raise BadFileError, "Bad file, #{response.code}"
      end
      done = true
    end
    request.run
    return [content_type, body]
  end
  
  class BadFileError < StandardError
  end
end
