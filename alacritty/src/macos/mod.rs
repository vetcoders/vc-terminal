use objc2::runtime::AnyObject;
use objc2_foundation::{NSDictionary, NSString, NSUserDefaults, ns_string};

pub mod dock_icon;
pub mod locale;
pub mod proc;

/// UI ownership is explicit; it is separate from the product's signed admission.
#[derive(Clone, Copy)]
pub enum ApplicationRole {
    Standalone,
    Hosted,
}

impl ApplicationRole {
    pub fn from_hosted(hosted: bool) -> Self {
        if hosted { Self::Hosted } else { Self::Standalone }
    }

    pub fn activation_policy(self) -> Option<winit::platform::macos::ActivationPolicy> {
        match self {
            Self::Standalone => None,
            Self::Hosted => Some(winit::platform::macos::ActivationPolicy::Accessory),
        }
    }

    pub fn owns_dock_icon(self) -> bool {
        matches!(self, Self::Standalone)
    }
}

pub fn disable_autofill() {
    unsafe {
        NSUserDefaults::standardUserDefaults().registerDefaults(
            &NSDictionary::<NSString, AnyObject>::from_slices(
                &[ns_string!("NSAutoFillHeuristicControllerEnabled")],
                &[ns_string!("NO")],
            ),
        );
    }
}

#[cfg(test)]
mod tests {
    use super::ApplicationRole;
    use winit::platform::macos::ActivationPolicy;

    #[test]
    fn hosted_role_has_accessory_policy_and_no_dock_ownership() {
        let hosted = ApplicationRole::from_hosted(true);
        assert!(matches!(hosted.activation_policy(), Some(ActivationPolicy::Accessory)));
        assert!(!hosted.owns_dock_icon());
        let standalone = ApplicationRole::from_hosted(false);
        assert!(standalone.activation_policy().is_none());
        assert!(standalone.owns_dock_icon());
    }
}
