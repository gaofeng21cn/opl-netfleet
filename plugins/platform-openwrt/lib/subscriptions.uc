import { cursor } from "uci";

return function(context) {
	const UCI_PACKAGE = context.use("platform.runtime").UCI_PACKAGE;
	const quota_state = context.use("models.subscriptions").quota_state;
	const display_name = context.use("models.subscriptions").display_name;
	function subscription_exists(section) { return cursor().get(UCI_PACKAGE, section) == "subscription"; }
	function subscription_display_name(section) {
		const uci = cursor();
		return display_name({ id: section, name: uci.get(UCI_PACKAGE, section, "name"), alias: uci.get(UCI_PACKAGE, section, "alias") });
	}
	function subscription_options() {
		const result = [];
		cursor().foreach(UCI_PACKAGE, "subscription", (section) => {
			const name = section?.[".name"];
			if (type(name) != "string" || !match(name, /^[A-Za-z0-9_]+$/)) return;
			const display = display_name({ id: name, name: section?.name, alias: section?.alias });
			push(result, { ref: `subscription:${name}`, display_name: display });
		});
		for (let i = 1; i < length(result); i++) {
			for (let j = i; j > 0 && result[j].display_name < result[j - 1].display_name; j--) {
				const previous = result[j - 1];
				result[j - 1] = result[j]; result[j] = previous;
			}
		}
		return result;
	}
	function quantity(value) {
		if (type(value) != "string") return null;
		const text = lc(trim(value)), parts = split(text, " ");
		if (!length(parts) || parts[0] == "" || index(text, "unlimited") >= 0) return null;
		const number_parts = split(parts[0], "."), whole = int(number_parts[0] ?? "0");
		const fraction = length(number_parts) > 1 ? int(substr(`${number_parts[1]}000`, 0, 3)) : 0;
		const unit = parts[1] ?? "b";
		let multiplier = 1;
		if (unit == "kb" || unit == "kib") multiplier = 1024;
		else if (unit == "mb" || unit == "mib") multiplier = 1024 * 1024;
		else if (unit == "gb" || unit == "gib") multiplier = 1024 * 1024 * 1024;
		else if (unit == "tb" || unit == "tib") multiplier = 1024 * 1024 * 1024 * 1024;
		return int(((whole * 1000 + fraction) * multiplier) / 1000);
	}
	function subscription_quota(section, config) {
		const uci = cursor();
		const available_field = config?.available_field ?? "avaliable";
		const total_field = config?.total_field ?? "total", used_field = config?.used_field ?? "used";
		const expiry_raw = uci.get(UCI_PACKAGE, section, config?.expiry_field ?? "expire");
		const expires_at = type(expiry_raw) == "string" &&
			match(trim(expiry_raw), /^[0-9]{4}-[0-9]{2}-[0-9]{2}([ T][0-9]{2}:[0-9]{2}:[0-9]{2})?$/) ? trim(expiry_raw) : null;
		let available_raw = uci.get(UCI_PACKAGE, section, available_field);
		if (available_raw == null && available_field != "available") available_raw = uci.get(UCI_PACKAGE, section, "available");
		return quota_state({ available: quantity(available_raw),
			total: quantity(uci.get(UCI_PACKAGE, section, total_field)), used: quantity(uci.get(UCI_PACKAGE, section, used_field)),
			expires_at, reset_day: uci.get(UCI_PACKAGE, section, "quota_reset_day") });
	}
	return { subscription_exists, subscription_display_name, subscription_options, subscription_quota };
};
