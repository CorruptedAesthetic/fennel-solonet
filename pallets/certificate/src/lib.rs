#![cfg_attr(not(feature = "std"), no_std)]

pub use pallet::*;

#[cfg(test)]
mod mock;

#[cfg(test)]
mod tests;

#[cfg(feature = "runtime-benchmarks")]
mod benchmarking;

pub mod weights;
pub use weights::*;

const CERTIFICATE_EXISTS: bool = true;

#[frame_support::pallet]
pub mod pallet {
	use frame_support::{
        dispatch::{DispatchResultWithPostInfo, DispatchResult},
		pallet_prelude::*,
		traits::{Currency, LockIdentifier, LockableCurrency, WithdrawReasons},
	};
	use frame_system::pallet_prelude::*;

	use crate::{weights::WeightInfo, CERTIFICATE_EXISTS};

	type BalanceOf<T> =
		<<T as Config>::Currency as Currency<<T as frame_system::Config>::AccountId>>::Balance;

	#[pallet::config]
	pub trait Config: frame_system::Config {
		/// The overarching event type.
		type RuntimeEvent: From<Event<Self>> + IsType<<Self as frame_system::Config>::RuntimeEvent>;
		/// Weight information for extrinsics in this pallet.
		type WeightInfo: WeightInfo;
		type Currency: LockableCurrency<
			Self::AccountId,
			Moment = frame_system::pallet_prelude::BlockNumberFor<Self>,
		>;
		/// The identifier for the lock used to store certificate deposits.
		type LockId: Get<LockIdentifier>;
		/// The price of a certificate lock.
		type LockPrice: Get<u32>;
	}

	#[pallet::pallet]
	pub struct Pallet<T>(_);

	#[pallet::storage]
	#[pallet::getter(fn certificate_list)]
	/// Maps accounts to the array of identities it owns.
	pub type CertificateList<T: Config> = StorageDoubleMap<
		_,
		Blake2_128Concat,
		T::AccountId,
		Blake2_128Concat,
		T::AccountId,
		bool,
		ValueQuery,
	>;

	#[pallet::event]
	#[pallet::generate_deposit(pub(super) fn deposit_event)]
	pub enum Event<T: Config> {
        /// A `certificate` was sent.
		CertificateSent { sender: T::AccountId, recipient: T::AccountId },
        /// A `certificate` was revoked.
		CertificateRevoked { sender: T::AccountId, recipient: T::AccountId },
        CertificateLock { account: T::AccountId, amount: BalanceOf<T> },
        CertificateUnlock { account: T::AccountId, amount: BalanceOf<T> },
	}

	#[pallet::error]
	pub enum Error<T> {
		/// The current account does not own the certificate.
		CertificateNotOwned,
		/// The certificate already exists.
		CertificateExists,
		InsufficientBalance,
	}

	#[pallet::call]
	impl<T: Config> Pallet<T> {
		/// Creates an on-chain event with a Certificate payload defined as part of the transaction
		/// and commits the details to storage.
		#[pallet::weight(T::WeightInfo::send_certificate())]
		#[pallet::call_index(0)]
        pub fn send_certificate(origin: OriginFor<T>, recipient: T::AccountId) -> DispatchResultWithPostInfo {
			let who = ensure_signed(origin)?;
			if T::Currency::total_balance(&who) < T::Currency::minimum_balance() {
				return Err(Error::<T>::InsufficientBalance.into());
			}
			ensure!(
				!CertificateList::<T>::contains_key(&who, &recipient),
				Error::<T>::CertificateExists
			);
			// Insert a placeholder value into storage - if the pair (who, recipient) exists, we
			// know there's a certificate present for the pair, regardless of value.
			T::Currency::set_lock(T::LockId::get(), &who, 10u32.into(), WithdrawReasons::all());
            Self::deposit_event(Event::CertificateLock { account: who.clone(), amount: T::Currency::free_balance(&who) });
			<CertificateList<T>>::try_mutate(
				&who,
				recipient.clone(),
				|certificate| -> DispatchResult {
					*certificate = CERTIFICATE_EXISTS;
					Ok(())
				},
			)?;
            Self::deposit_event(Event::CertificateSent { sender: who.clone(), recipient: recipient.clone() });
            Ok(().into())
		}
		#[pallet::weight(T::WeightInfo::revoke_certificate())]
		#[pallet::call_index(1)]
		/// Revokes the identity with ID number identity_id, as long as the identity is owned by
		/// origin.
		pub fn revoke_certificate(origin: OriginFor<T>, recipient: T::AccountId) -> DispatchResultWithPostInfo {
			let who = ensure_signed(origin)?;
			if T::Currency::total_balance(&who) < T::Currency::minimum_balance() {
				return Err(Error::<T>::InsufficientBalance.into());
			}
			ensure!(
				CertificateList::<T>::contains_key(&who, &recipient),
				Error::<T>::CertificateNotOwned
			);
			T::Currency::remove_lock(T::LockId::get(), &who);
            Self::deposit_event(Event::CertificateUnlock { account: who.clone(), amount: T::Currency::free_balance(&who) });
			<CertificateList<T>>::try_mutate(
				&who,
				recipient.clone(),
				|certificate| -> DispatchResult {
					*certificate = !CERTIFICATE_EXISTS;
					Ok(())
				},
			)?;
            Self::deposit_event(Event::CertificateRevoked { sender: who.clone(), recipient: recipient.clone() });
            Ok(().into())
		}
	}
}
