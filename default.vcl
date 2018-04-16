# This is a basic VCL configuration file for varnish.  See the vcl(7)
# man page for details on VCL syntax and semantics.
#
# Default backend definition.  Set this to point to your content
# server.
#
backend default {
  .host = "127.0.0.1";
  .port = "8080";
}

#------------------------------------------------------------------------------------------------
# mcdaniel
# apr-2018
#
# Varnish configuration for Wordpress backend.
#
# Additional research sources for customization Varnish for Wordpress:
#   https://info.varnish-software.com/blog/step-step-speed-wordpress-varnish-software
#   https://www.modpagespeed.com/doc/downstream-caching
#   https://gist.github.com/matthewjackowski/062be03b41a68edbadfc
#   https://www.fastly.com/blog/overriding-origin-ttl-varnish-or-my-beginners-mistake
#   https://info.varnish-software.com/blog/step-step-speed-wordpress-varnish-software
#------------------------------------------------------------------------------------------------
sub vcl_deliver {
    # backend is down
    if (resp.status == 503) {
        return(restart);
    }
    if (resp.http.magicmarker) {
       # Remove the magic marker
        unset resp.http.magicmarker;

       # By definition we have a fresh object
       set resp.http.age = "0";
     }
   if (obj.hits > 0) {
     set resp.http.X-Cache = "HIT";
   } else {
     set resp.http.X-Cache = "MISS";
   }
   set resp.http.Access-Control-Allow-Origin = "*";
}

sub vcl_fetch {
  set beresp.ttl = 7d;
}

sub vcl_error {
    # redirect http to https
    if(obj.status == 850) {
        set obj.http.Location = "https://" + req.http.host + req.url;
        set obj.status = 301;
        return(deliver);
    }
}

sub vcl_recv {

  # PRIORITY 1
  #------------------------------------------------------------------------------------------------
  # look for uptime, health checkers, and friendly robots.
  # pass these thru right away.
  #
  if (req.http.User-Agent) {
    if (req.http.User-Agent ~ "^ELB-HealthChecker" ||     #AWS ELB health check
        req.http.User-Agent ~ "^WP Rocket" ||             #WP Rocket performance plugin. installed on all sites.
        req.http.User-Agent ~ "^Pingdom.com" ||           #uptime monitor
        req.http.User-Agent ~ "^jetmon") {                #uptime monitor
     return (lookup);
    }
  }


  # PRIORITY 2
  #------------------------------------------------------------------------------------------------
  # redirect all other http requests to https
  if (req.http.X-Forwarded-Proto !~ "https") {
   error 850 "Moved permanently";
  }

  # look for friendly robots. send these straight to cache pool after having verified
  # that we have an https request
  if (req.http.User-Agent) {
    if (req.http.User-Agent ~ "^facebookexternalhit" ||   #bot
        req.http.User-Agent ~ "Googlebot" ||              #bot
        req.http.User-Agent ~ "bingbot" ||                #bot
        req.http.User-Agent ~ "AhrefsBot" ||              #bot
        req.http.User-Agent ~ "YandexBot" ||              #bot
        req.http.User-Agent ~ "^Baiduspider") {                #uptime monitor
     return (lookup);
    }
  }



  # PRIORITY 3
  #------------------------------------------------------------------------------------------------
  # Pass logged in Wordpress users and any console url's directly to backend with any modification.

  # pass wp-admin urls
   if (req.url ~ "(wp-login|wp-admin)" || req.url ~ "preview=true" || req.url ~ "xmlrpc.php") {
    return (pass);
   }
  # pass wp-admin cookies
  if (req.http.cookie) {
    if (req.http.cookie ~ "(wordpress_|wp-settings-)") {
        return(pass);
    }
  }

  #catch any non-cacheable sessions and / or WP console pages.
  if (req.http.Authorization ||
      #req.http.Cookie ||
      req.url ~ "wp-(login|admin|comments-post.php|cron.php)" ||
      req.url ~ "preview=true" ||
      req.url ~ "xmlrpc.php") {
      return (pass);
  }

  # we probably caught all of the logged in Wordpress users already, but just in case ...
  if (req.http.User-Agent) {
    if (req.http.User-Agent ~ "^Wordpress") {
      return (pass);
    }
  }


  # PRIORITY 4
  #------------------------------------------------------------------------------------------------
  # Do everything we can to make each remaining request cacheable.

  # Wordpress adds cookies to a lot of things, but most of these cookies are only really
  # necesary if the user is logged in and editing content. Logged in users were passed to the backen
  # in PRIORITY 2, so we can safely drop cookies and params from any requests for static assets
  if (req.url ~ "\.(gif|jpg|jpeg|svg|swf|ttf|css|js|flv|mp3|mp4|pdf|ico|png)(\?.*|)$") {
    unset req.http.cookie;
    set req.url = regsub(req.url, "\?.*$", "");
  }

  # drop tracking params
  if (req.url ~ "\?(utm_(campaign|medium|source|term)|adParams|client|cx|eid|fbid|feed|ref(id|src)?|v(er|iew))=") {
    set req.url = regsub(req.url, "\?.*$", "");
  }


  if (req.http.Accept-Encoding) {
    if (req.url ~ "\.(jpg|png|gif|gz|tgz|bz2|tbz|mp3|ogg)$") {
        # No point in compressing these
        remove req.http.Accept-Encoding;
    } elsif (req.http.Accept-Encoding ~ "gzip") {
        set req.http.Accept-Encoding = "gzip";
    } elsif (req.http.Accept-Encoding ~ "deflate") {
        set req.http.Accept-Encoding = "deflate";
    } else {
        # unkown algorithm
        remove req.http.Accept-Encoding;
    }

  }

  # PRIORITY 5
  #------------------------------------------------------------------------------------------------
  # And finally, unset headers that might cause us to cache duplicate info. Of these, cookie and User-Agent
  # seem to be the biggest culprits for ruining the best laid caching strategies. Since the user is not logged in
  # we'll need neither the cookie or the User-Agent, and for that matter, we "PROBABLY" do not need a language header eitherl
  if(req.http.cookie) {
    unset req.http.cookie;
  }
  if(req.http.Accept-Language) {
    unset req.http.Accept-Language;
  }
  if(req.http.User-Agent) {
    unset req.http.User-Agent;
  }

}

sub vcl_hash {
   if ( req.http.X-Forwarded-Proto ) {
    hash_data( req.http.X-Forwarded-Proto );
   }
}


# Below is a commented-out copy of the default VCL logic.  If you
# redefine any of these subroutines, the built-in logic will be
# appended to your code.
# sub vcl_recv {
#     if (req.restarts == 0) {
# 	if (req.http.x-forwarded-for) {
# 	    set req.http.X-Forwarded-For =
# 		req.http.X-Forwarded-For + ", " + client.ip;
# 	} else {
# 	    set req.http.X-Forwarded-For = client.ip;
# 	}
#     }
#     if (req.request != "GET" &&
#       req.request != "HEAD" &&
#       req.request != "PUT" &&
#       req.request != "POST" &&
#       req.request != "TRACE" &&
#       req.request != "OPTIONS" &&
#       req.request != "DELETE") {
#         /* Non-RFC2616 or CONNECT which is weird. */
#         return (pipe);
#     }
#     if (req.request != "GET" && req.request != "HEAD") {
#         /* We only deal with GET and HEAD by default */
#         return (pass);
#     }
#     if (req.http.Authorization || req.http.Cookie) {
#         /* Not cacheable by default */
#         return (pass);
#     }
#     return (lookup);
# }
#
# sub vcl_pipe {
#     # Note that only the first request to the backend will have
#     # X-Forwarded-For set.  If you use X-Forwarded-For and want to
#     # have it set for all requests, make sure to have:
#     # set bereq.http.connection = "close";
#     # here.  It is not set by default as it might break some broken web
#     # applications, like IIS with NTLM authentication.
#     return (pipe);
# }
#
# sub vcl_pass {
#     return (pass);
# }
#
# sub vcl_hash {
#     hash_data(req.url);
#     if (req.http.host) {
#         hash_data(req.http.host);
#     } else {
#         hash_data(server.ip);
#     }
#     return (hash);
# }
#
# sub vcl_hit {
#     return (deliver);
# }
#
# sub vcl_miss {
#     return (fetch);
# }
#
# sub vcl_fetch {
#     if (beresp.ttl <= 0s ||
#         beresp.http.Set-Cookie ||
#         beresp.http.Vary == "*") {
# 		/*
# 		 * Mark as "Hit-For-Pass" for the next 2 minutes
# 		 */
# 		set beresp.ttl = 120 s;
# 		return (hit_for_pass);
#     }
#     return (deliver);
# }
#
# sub vcl_deliver {
#     return (deliver);
# }
#
# sub vcl_error {
#     set obj.http.Content-Type = "text/html; charset=utf-8";
#     set obj.http.Retry-After = "5";
#     synthetic {"
# <?xml version="1.0" encoding="utf-8"?>
# <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN"
#  "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">
# <html>
#   <head>
#     <title>"} + obj.status + " " + obj.response + {"</title>
#   </head>
#   <body>
#     <h1>Error "} + obj.status + " " + obj.response + {"</h1>
#     <p>"} + obj.response + {"</p>
#     <h3>Guru Meditation:</h3>
#     <p>XID: "} + req.xid + {"</p>
#     <hr>
#     <p>Varnish cache server</p>
#   </body>
# </html>
# "};
#     return (deliver);
# }
#
# sub vcl_init {
# 	return (ok);
# }
#
# sub vcl_fini {
# 	return (ok);
# }
