import js.node.*;
import js.node.http.*;
import js.Promise;

class Main {
	static function safeUser(basic:String)
	{
		var basic = basic.split(":");
		if (basic.length != 2)
			throw "ERR: invalid Basic HTTP authentication";
		var user = basic[0];
		var pwd = basic[1];
		if ((user == pwd || pwd == "" || ~/oauth/.match(pwd)) && user.length > 5)
			user = user.substr(0, 5) + "...";
		return user;
	}

	static function parseAuth(s:String)
	{
		if (s == null)
			return null;
		var parts = s.split(" ");
		if (parts[0] != "Basic")
			throw "ERR: HTTP authentication schemes other than Basic not supported";
		return {
			authorization : s,
			basic : haxe.crypto.Base64.decode(parts[1]).toString()
		}
	}

	static function getParams(req:IncomingMessage)
	{


		var gitr = ~/^\/(.+)(.git)?\/(info\/refs\?service=)?(git-[^-]+-pack)$/;
		var lfsr = ~/^\/(.+)(.git)?\/(objects\/batch)$/;	

		//Match url for non lfs url 
		trace('generating params from request url: ' + req.url);
		if (gitr.match(req.url)){
			return {
				repo : removeLineEndingsReg.replace(gitr.matched(1), ""),
				auth : parseAuth(req.headers["authorization"]),
				service : gitr.matched(4),
				isInfoRequest : gitr.matched(3) != null
			}
		}
		if(lfsr.match(req.url)){
			return{
				throw 'Caught batch URL: '+ req.url;
			}
		}
		else{
			throw 'Cannot deal with url';
		}

	}

	static function clone(remote, local, callback)
	{
		trace('cloneing!');
		trace("Remote: "+ remote);
		trace("Local: "+ local);
		trace("Full command: git clone "+ remote + " " + local);
		trace("clone command printed");
		var proc = ChildProcess.exec('git clone --mirror "$remote" "$local"', callback);
		proc.stdout.on('data', function(data){
			trace(data);
		});
		proc.stderr.on('data', function(data){
			trace(data);
		});
	}

	static function fetch(remote, local, callback)
	{
		ChildProcess.exec('git -C "$local" remote set-url origin "$remote"', function(err, stdout, stderr) {
			ChildProcess.exec('git -C "$local" fetch --quiet', callback);
		});
	}

	static function lfsFetch(remote, local, callback)
	{
		//TODO: --all is slow. would this work without it?
		ChildProcess.exec('git -C "$local" remote set-url origin "$remote"', function(err, stdout, stderr) {
			var proc = ChildProcess.exec('git -C "$local" lfs fetch --all "$remote"', callback);
			// get lfs output as it happens
			proc.stdout.on('data', function(data) {
				trace(data);	
			});
		});

	}

	static function authenticate(params, infos, callback)
	{
		trace('INFO: authenticating on the upstream repo $infos');
		var req = Https.request('https://${params.repo}/info/refs?service=${params.service}', callback);
		req.setHeader("User-Agent", "git/");
		if (params.auth != null)
			req.setHeader("Authorization", params.auth.authorization);
		req.end();
	}


	// Update the cached repo in question by either fetching, or if the local path is not found, cloning
	static function update(remote, local, infos, callback)
	{
		if (!updatePromises.exists(local)) {
			updatePromises[local] = new Promise(function(resolve, reject) {

				//Handle updating git base repo
				trace('INFO: updating: fetching from $infos');
				fetch(remote, local, function (ferr, stdout, stderr) {
					if (ferr != null) {
						trace("WARN: updating: fetch failed");
						trace("WARN: continuing with clone");
						clone(remote, local, function (cerr, stdout, stderr) {
							if (cerr != null) {
								resolve('ERR: git clone exited with non-zero status: ${cerr.code}');
							} 
							else {
								trace("INFO: updating via clone: success");
								resolve(null);
							}
						});
					} 
					else {
						trace("INFO: updating via git fetch: success");
						resolve(null);
					}
				});
			})
			.then(function(result) {

				// Handle LFS update
				// non null result causes this to be bypassed
				return new Promise(function(resolve, reject) {
					if (result == null && lfs) {
						lfsFetch(remote, local, function (lerr, stdout, stderr) {
							if(lerr != null)
							{	
								resolve('ERR: git lfs fetch exited with 
									non-zero status: ${lerr.code}');
							}
							else
							{
								trace('INFO: lfs fetch: success');
								resolve(null);
							}
						});
					}
					else {
						resolve(result);
					}
				});
			})
			.then(function(success) {
				updatePromises.remove(local);
				return Promise.resolve(success);
			})
			.catchError(function(err) {
				// Will be called when an error is thrown. Note success function may execute if an error is resolved.
				updatePromises.remove(local);
				return Promise.reject(err);
			});
		} else {
			trace("INFO: reusing existing promise");
		}
		return updatePromises[local]
		.then(function(nothing:Dynamic) {
			trace("INFO: promise fulfilled");
			callback(null);
		}, function(err:Dynamic) {
			callback(err);
		});
	}
	
	// Entry point for request see: https://www.w3schools.com/nodejs/func_http_requestlistener.asp 
	static function handleRequest(req:IncomingMessage, res:ServerResponse)
	{
		try {
			trace('Handling New Request: ${req.method} ${req.url}');

			//get params from request, ensure the request is supported
			var params = getParams(req);
			var infos = '${params.repo}';
			if (params.auth != null)
				infos += ' (user ${safeUser(params.auth.basic)})';
			
			switch ([req.method == "GET", params.isInfoRequest]) {
			case [false, false], [true, true]:  // ok
			case [m, i]: throw 'isInfoRequest=$i but isPOST=$m';
			}

			//authenticate
			if (params.service != "git-upload-pack")
				throw 'Service ${params.service} not supported yet';

			var remote = if (params.auth == null)
				'https://${params.repo}';
			else
				'https://${params.auth.basic}@${params.repo}';

			trace("Cache Dir: " + cacheDir);
			trace("Repo: " + params.repo);

			var local = Path.join(cacheDir, params.repo);

			trace("After join: " + local);
		
			authenticate(params, infos, function (upRes) {
				switch (upRes.statusCode) {
				case 401, 403, 404:
					res.writeHead(upRes.statusCode, upRes.headers);
					res.end();
					return;
				case 200:  // ok
				}

				if (params.isInfoRequest) {
					update(remote, local, infos, function (err) {
						//after updating we check for errors and then call a service to update the caller
						if (err != null) {
							trace('ERR: $err');
							trace(haxe.CallStack.toString(haxe.CallStack.exceptionStack()));
							res.statusCode = 500;
							res.end();
							return;
						}
						res.statusCode = 200;
						res.setHeader("Content-Type", 'application/x-${params.service}-advertisement');
						res.setHeader("Cache-Control", "no-cache");
						res.write("001e# service=git-upload-pack\n0000");
						var up = ChildProcess.spawn(params.service, ["--stateless-rpc", "--advertise-refs", local]);
						up.stdout.pipe(res);
						up.stderr.on("data", function (data) trace('${params.service} stderr: $data'));
						up.on("exit", function (code) {
							if (code != 0)
								res.end();
							trace('INFO: ${params.service} done with exit $code');
						});
					});
				} else {
					res.statusCode = 200;
					res.setHeader("Content-Type", 'application/x-${params.service}-result');
					res.setHeader("Cache-Control", "no-cache");
					var up = ChildProcess.spawn(params.service, ["--stateless-rpc", local]);
                                        // If we receive gzip content, we must unzip
                                        if (req.headers['content-encoding'] == 'gzip')
                                                req.pipe(Zlib.createUnzip()).pipe(up.stdin);
                                        else
                                                req.pipe(up.stdin);
					up.stdout.pipe(res);
					up.stderr.on("data", function (data) trace('${params.service} stderr: $data'));
					up.on("exit", function (code) {
						if (code != 0)
							res.end();
						trace('${params.service} done with exit $code');
					});
				}
			});
		} catch (err:Dynamic) {
			trace('ERROR: $err');
			trace(haxe.CallStack.toString(haxe.CallStack.exceptionStack()));
			res.statusCode = 500;
			res.end();
		}
	}
	
	static var updatePromises = new Map<String, Promise<Dynamic>>();
	static var removeLineEndingsReg = ~/(\r\n\t|\n|\r\t|\r\n|\r)/gm;
	static var cacheDir = "/tmp/var/cache/git/";
	static var listenPort = 8080;
	static var lfs = false;
	static var version = "0.0";
	static var usage = "
A caching Git HTTP server.

Serve local mirror repositories over HTTP/HTTPS, updating them as they are requested.

Usage:
  git-cache-http-server.js [options]

Options:
  -c,--cache-dir <path>   Location of the git cache [default: /var/cache/git]
  -p,--port <port>        Bind to port [default: 8080]
  --lfs			  Enable git LFS
  -h,--help               Print this message
  --version               Print the current version
";

	static function main()
	{
		//Set configuration
		version = Version.readPkg(); 
		var options = js.npm.Docopt.docopt(usage, { version : version });
		cacheDir = removeLineEndingsReg.replace(options["--cache-dir"], "");
		listenPort = Std.parseInt(options["--port"]);
		lfs = options["--lfs"];
		if (listenPort == null || listenPort < 1 || listenPort > 65535){
			throw 'Invalid port number: ${options["--port"]}';
		}

		//Print startup configuration
		trace('\n======| Git Cache HTTP Server $version |======');
		trace('INFO: cache directory: $cacheDir');
		trace('INFO: listening to port: $listenPort');
		if(lfs){
			trace('INFO: LFS enabled. Expecing an LFS enabled upstream.');
		}

		Http.createServer(handleRequest).listen(listenPort);
	}
}

