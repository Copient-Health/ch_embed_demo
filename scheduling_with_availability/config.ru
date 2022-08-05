require 'yaml'
require 'erb'
require 'net/http'
require 'json'
require 'csv'

class EmbedDemo
  def self.neighbor_path(filename)
    File.expand_path("../#{filename}", __FILE__)
  end

  def self.load_environment
    env_file = neighbor_path('environment.yml')
    return {} unless File.exists?(env_file)

    YAML.load(File.read(env_file)).each_pair do |key, value|
      ENV[key.to_s] = value
    end
  end

  load_environment
  CONTENT_TEMPLATE = ERB.new(File.read(neighbor_path('lander.html.erb')))
  CPT_LIST = CSV.read(neighbor_path('surgical_cpt_list.csv'), headers: true)
  HCPC_LIST = CSV.read(neighbor_path('hcpc_codes.csv'), headers: true)

  def call(env)
    request = Rack::Request.new(env)
    @physician_list ||= fetch_physicians_from_copient
    case request.request_method
    when 'GET'
      page_view = 'initial'
      known_surgeons = (@physician_list || [])
        .sort_by { |s| s.values_at('last_name', 'first_name') }
        .map do |surgeon|
          [surgeon.values_at('first_name', 'last_name').join(' '),
           surgeon['provider_id']]
        end
    when 'POST'
      if request.POST['completed']
        page_view = 'complete'
      else
        page_view = 'scheduling'
        calendar_url = fetch_embed_url_from_copient(request.POST)
        selected_surgeon = @physician_list&.find { |s| s['provider_id'] == request.POST['physician'] }
      end
    else
      return [405, {}, ["Method not allowed: #{env['REQUEST_METHOD']}"]]
    end

    [
      200,
      { 'Content-Type' => 'text/html' },
      [CONTENT_TEMPLATE.result(binding)]
    ]
  end

  private

  def fetch_physicians_from_copient
    uri = URI("#{ENV['COPIENT_API_ROOT']}/v1/physicians")
    uri.query = URI.encode_www_form(base_api_params.to_a)
    req = Net::HTTP::Get.new(uri)
    req['Authorization'] = "Bearer #{ENV['COPIENT_EMBED_KEY']}"

    res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, verify_mode: OpenSSL::SSL::VERIFY_NONE) do |http|
      http.request(req)
    end
    @copient_response = res
    return unless res.is_a?(Net::HTTPSuccess)

    JSON.parse(res.body)['physicians']
  end

  def fetch_embed_url_from_copient(submitted_data)
    uri = URI("#{ENV['COPIENT_API_ROOT']}/v1/embeds")
    req = Net::HTTP::Post.new(uri)
    req['Authorization'] = "Bearer #{ENV['COPIENT_EMBED_KEY']}"
    req.set_form_data(
      base_api_params
       .merge(page: 'availability')
       .merge(submitted_data.compact)
    )
    res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, verify_mode: OpenSSL::SSL::VERIFY_NONE) do |http|
      http.request(req)
    end
    return '' unless res.is_a?(Net::HTTPSuccess)

    JSON.parse(res.body)['url']
  end

  def base_api_params
    @base_api_params ||= {
      'client_subdomain' => ENV['COPIENT_APP_SUBDOMAIN'],
      'user_email' => ENV['COPIENT_USER_EMAIL']
    }
  end
end

run EmbedDemo.new
