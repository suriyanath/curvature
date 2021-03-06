require 'net/http'
require 'json'
require 'uri'

##Handles login and cookie data. Identity initially returns only an unscoped token (a token with no tenant) that can
##only be used to retrive a list of tenants. Reauthenticating as one of those tenants will give you access to the
##components of openstack that tenant has access too.

##A recent bug with OpenStack providing tokens bigger than allowed cookie size means that we are storing the token
##rails side, and accessing this using the session.

##http://docs.openstack.org/api/openstack-identity-service/2.0/content/

class LoginsController < ApplicationController
  before_filter :check_login, :only => :show

  ##Supported Browsers
  Browser = Struct.new(:browser, :version)
  SupportedBrowsers = [
    Browser.new('Safari', '6.0.2'),
    Browser.new('Firefox', '19.0.2'),
    Browser.new('Chrome', '25.0.1364.160')
  ]

  def show
    @unsupported = false
    user_agent = UserAgent.parse(request.user_agent)
    unless SupportedBrowsers.detect { |browser| user_agent >= browser }
      browser_name = user_agent.browser
      if (browser_name.casecmp("safari") == 0 || browser_name.casecmp("firefox") == 0 || browser_name.casecmp("chrome") == 0)
        flash_string = "You appear to be using an unsupported version of " + browser_name + ". Please upgrade for the best experience."
      else
        flash_string = "You appear to be using an unsupported browser."
        @unsupported = true
      end
      flash[:unsupported] = flash_string
    end

    logger.info(APP_CONFIG)

    if(!APP_CONFIG.has_key?("identity"))
      redirect_to setup_url
    else
      respond_to do |format|
        format.html
      end
    end
  end

  ##Attempt login, store cookie, 
  def create
    begin
      identity = Ropenstack::Identity.new(APP_CONFIG["identity"]["ip"], APP_CONFIG["identity"]["port"], nil,"identityv2")

      identity.authenticate(params[:username], params[:password])

      #Set user id---------------------------------------------------------------
      sesh :current_user_id, identity.user()["id"]
      sesh :current_token, identity.token()

      #Get Default Tenant--------------------------------------------------------
      tenant_data = identity.tenant_list()
      sesh :current_tenant, tenant_data["tenants"][0]["id"]
      sesh :current_tenant_name, tenant_data["tenants"][0]["name"]

      #Use this to get a scoped token--------------------------------------------
      identity.scope_token(tenant_data["tenants"][0]["name"])		
      sesh :current_token, identity.token()

      #Parse Service Catalog-----------------------------------------------------
      logger.info(identity.services())
      store_services(identity.services(), identity.admin())

      #Redirect to the curvature dashboard after successfully logging in
      redirect_to visualisation_url	
    rescue Ropenstack::UnauthorisedError
      login_failed()
    rescue Ropenstack::TimeoutError
      timeout()
    end
  end
  
  ##Reauthenticate and set new scoped token
  def switch
    identity = Ropenstack::Identity.new(APP_CONFIG["identity"]["ip"], APP_CONFIG["identity"]["port"], (sesh :current_token), "identityv2")
    identity.scope_token(params[:tenant_name])
    store_services(identity.services(), identity.admin())	
    sesh :current_tenant, identity.token_metadata()["tenant"]["id"]
    sesh :current_tenant_name, identity.token_metadata()["tenant"]["name"]
    sesh :current_token, identity.token()
    redirect_to visualisation_url
  end

  ##Used to fill out tenant switching bar in interface.
  def tenants
    identity = Ropenstack::Identity.new(APP_CONFIG["identity"]["ip"], APP_CONFIG["identity"]["port"], (sesh :current_token), "identityv2")
    respond_to do |format|
      format.json { render :json => identity.tenant_list() }
    end
  end

  def current
    current_name = sesh :current_tenant_name
    respond_to do |format|
      format.json { render :json => {"tenant" => current_name} }
    end
  end  

  def services
    servs = sesh :services
    respond_to do |format|
      format.json { render :json => { "services" => servs } }
    end
  end

  ##Logout/destroy tokens
  def destroy
    cookies.delete :sesh_id
    flash.keep
    redirect_to root_url, :notice => "You have logged out successfully!" 
  end

  private

  def store_services(services, admin)
    servs = ""
    first = true
    services.each do |service|
      if first
        servs = "#{service["type"]}"
        first = false
      else
        servs = "#{servs},#{service["type"]}"
      end
      name = service["type"] + "_ip"
      sesh name.to_sym, service["endpoints"][0]["publicURL"]
      logger.info service["endpoints"][0]["publicURL"]
    end
    if admin
      servs = "#{servs},admin"
    end
    sesh :services, servs
  end

  def check_login
    if logged_in?
      redirect_to visualisation_url
    end
  end

  def login_failed
    flash[:error] = "Login Unsuccessful!"
    redirect_to root_url
  end

  def timeout
    flash[:error] = "Timeout connecting to Openstack"
    redirect_to root_url
  end
end
