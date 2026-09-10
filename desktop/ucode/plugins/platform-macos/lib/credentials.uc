const rpc = global.__netfleetDesktopOwner.rpc;
return function(context) {
	return { api_secret: () => rpc('state.get').controllerSecret, proxy_authentication: () => null };
};
