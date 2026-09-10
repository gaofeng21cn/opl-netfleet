const rpc = global.__netfleetDesktopOwner.rpc;
return function(context) {
	return { current_profile: () => rpc('state.get').profile,
		backend_enabled: () => rpc('state.get').enabled == true,
		set_backend_enabled: enabled => rpc('state.patch', { enabled: enabled == true }).ok == true,
		set_profile: profile => rpc('state.patch', { profile }).ok == true };
};
