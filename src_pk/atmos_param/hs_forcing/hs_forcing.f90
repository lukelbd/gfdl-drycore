
module hs_forcing_mod

!-----------------------------------------------------------------------

use     constants_mod, only: KAPPA, CP_AIR, GRAV, PI

use           fms_mod, only: error_mesg, FATAL, file_exist,       &
                             open_namelist_file, check_nml_error, &
                             mpp_pe, mpp_root_pe, close_file,     &
                             write_version_number, stdlog,        &
                             uppercase

use  time_manager_mod, only: time_type, get_time

use  diag_manager_mod, only: register_diag_field, send_data

use  field_manager_mod, only: MODEL_ATMOS, parse
use tracer_manager_mod, only: query_method, get_number_tracers

use           tstd_mod, only: us_tstd_1d, us_tstd_2d

implicit none
private

!-----------------------------------------------------------------------
!---------- interfaces ------------

   public :: hs_forcing, hs_forcing_init

!-----------------------------------------------------------------------
!-------------------- namelist -----------------------------------------

   character(len=64) :: damp = 'linear'

   logical :: no_forcing = .false., pk_strat = .false., strat_sponge = .false.

   real :: t_zero=315., t_strat=200., delh=60., delv=10., eps=0., sigma_b=0.7
   real :: vtx_edge = 50., vtx_wid = 10., vtx_gam = 1.e-3
   real :: P00 = 1.e5, p_sponge = 5.e-4, p_tropopause = 0.1

   real :: ka = -40. !  negative values are damping time in days
   real :: ks =  -4., kf = -1.
   real :: k_sponge = -2.
   real :: k_strat  = -40.
   real :: k_top    = -3.

   logical :: do_conserve_energy = .true.

   real :: trflux = 1.e-5   !  surface flux for optional tracer
   real :: trsink = -4.     !  damping time for tracer

!-----------------------------------------------------------------------

   namelist /hs_forcing_nml/  no_forcing, pk_strat, strat_sponge, t_zero, &
                              t_strat, delh, delv, eps, sigma_b, vtx_edge, &
                              vtx_wid, vtx_gam, P00, p_sponge, p_tropopause, ka, &
                              ks, kf, k_sponge, k_strat, k_top, damp, &
                              do_conserve_energy, trflux, trsink

!-----------------------------------------------------------------------

   character(len=128) :: version='$Id: hs_forcing.f90,v 13.0 2006/03/28 21:10:03 fms Exp $'
   character(len=128) :: tagname='$Name: latest $'

   real :: tka, tks, vkf, vks, tkstr, tktop
   real :: trdamp

   integer :: id_teq, id_tdt, id_udt, id_vdt,  &
              id_tdt_diss, id_diss_heat, id_tstd, &
              id_ttrop
   real    :: missing_value = -1.e10
   character(len=14) :: mod_name = 'hs_forcing'

   logical :: module_is_initialized = .false.

!-----------------------------------------------------------------------

contains

!#######################################################################

 subroutine hs_forcing ( is, ie, js, je, dt, Time, lat, p_half, p_full, &
                         u, v, t, r, um, vm, tm, rm, udt, vdt, tdt, &
                         rdt, mask, kbot )

!-----------------------------------------------------------------------
   integer, intent(in)                        :: is, ie, js, je
      real, intent(in)                        :: dt
 type(time_type), intent(in)                  :: Time
      real, intent(in),    dimension(:,:)     :: lat
      real, intent(in),    dimension(:,:,:)   :: p_half, p_full
      real, intent(in),    dimension(:,:,:)   :: u, v, t, um, vm, tm
      real, intent(in),    dimension(:,:,:,:) :: r, rm
      real, intent(inout), dimension(:,:,:)   :: udt, vdt, tdt
      real, intent(inout), dimension(:,:,:,:) :: rdt

      real, intent(in),    dimension(:,:,:), optional :: mask
   integer, intent(in),    dimension(:,:)  , optional :: kbot
!-----------------------------------------------------------------------
   real, dimension(size(t,1),size(t,2))           :: ps, diss_heat
   real, dimension(size(t,1),size(t,2),size(t,3)) :: ttnd, utnd, vtnd, teq, pmass
   real, dimension(size(r,1),size(r,2),size(r,3)) :: rst, rtnd
   real, dimension(size(r,1),size(r,2),size(r,3)) :: t_trop, uspg, vspg
   integer :: i, j, k, kb, n, num_tracers
   logical :: used
   real    :: flux, sink, value
   character(len=128) :: scheme, params

!-----------------------------------------------------------------------
     if (no_forcing) return

     if (.not.module_is_initialized) call error_mesg ('hs_forcing','hs_forcing_init has not been called', FATAL)

!-----------------------------------------------------------------------
!     surface pressure

     if (present(kbot)) then
         do j=1,size(p_half,2)
         do i=1,size(p_half,1)
            kb = kbot(i,j)
            ps(i,j) = p_half(i,j,kb+1)
         enddo
         enddo
     else
            ps(:,:) = p_half(:,:,size(p_half,3))
     endif

!-----------------------------------------------------------------------
!     rayleigh damping of wind components near the surface

      call rayleigh_damping ( ps, p_full, u, v, utnd, vtnd, mask=mask )

      if (do_conserve_energy) then
         ttnd = -((um+.5*utnd*dt)*utnd + (vm+.5*vtnd*dt)*vtnd)/CP_AIR
         tdt = tdt + ttnd
         if (id_tdt_diss > 0) used = send_data ( id_tdt_diss, ttnd, Time, is, js)
       ! vertical integral of ke dissipation
         if ( id_diss_heat > 0 ) then
          do k = 1, size(t,3)
            pmass(:,:,k) = p_half(:,:,k+1)-p_half(:,:,k)
          enddo
          diss_heat = CP_AIR/GRAV * sum( ttnd*pmass, 3)
          used = send_data ( id_diss_heat, diss_heat, Time, is, js)
         endif
      endif

!-----------------------------------------------------------------------
!     sponge layer damping of wind components at the top

      if (strat_sponge) then
         call sponge_layer ( ps, p_full, u, v, uspg, vspg, mask=mask )
      endif
      utnd(:,:,:) = utnd(:,:,:) + uspg(:,:,:)
      vtnd(:,:,:) = vtnd(:,:,:) + vspg(:,:,:)

!-----------------------------------------------------------------------
!     finalize d/dt terms and send data

      udt(:,:,:)  = udt(:,:,:) + utnd(:,:,:)
      vdt(:,:,:)  = vdt(:,:,:) + vtnd(:,:,:)

      if (id_udt > 0) used = send_data ( id_udt, utnd, Time, is, js)
      if (id_vdt > 0) used = send_data ( id_vdt, vtnd, Time, is, js)

!-----------------------------------------------------------------------
!     thermal forcing for held & suarez (1994) benchmark calculation

      call newtonian_damping ( Time, lat, ps, p_full, t, ttnd, teq, mask )

      tdt = tdt + ttnd

      if (id_tdt > 0) used = send_data ( id_tdt, ttnd, Time, is, js)
      if (id_teq > 0) used = send_data ( id_teq, teq,  Time, is, js)
!      if (id_tstd > 0) used = send_data ( id_tstd, tstd,  Time, is, js)
      if (id_ttrop > 0) used = send_data ( id_ttrop, t_trop,  Time, is, js)

!-----------------------------------------------------------------------
!     -------- tracers -------

      call get_number_tracers(MODEL_ATMOS, num_tracers=num_tracers)
      if(num_tracers == size(rdt,4)) then
        do n = 1, size(rdt,4)
           flux = trflux
           sink = trsink
           if (query_method('tracer_sms', MODEL_ATMOS, n, scheme, params)) then
               if (uppercase(trim(scheme)) == 'NONE') cycle
               if (uppercase(trim(scheme)) == 'OFF') then
                 flux = 0.; sink = 0.
               else
                 if (parse(params,'flux',value) == 1) flux = value
                 if (parse(params,'sink',value) == 1) sink = value
               endif
           endif
           rst = rm(:,:,:,n) + dt*rdt(:,:,:,n)
           call tracer_source_sink ( flux, sink, p_half, rst, rtnd, kbot )
           rdt(:,:,:,n) = rdt(:,:,:,n) + rtnd
        enddo
      else if(num_tracers == 0 .and. size(rdt,4) == 1) then ! allow this as a getaround for a problem with the solo fv model
        flux = trflux
        sink = trsink
        rst = rm(:,:,:,1) + dt*rdt(:,:,:,1)
        call tracer_source_sink ( flux, sink, p_half, rst, rtnd, kbot )
        rdt(:,:,:,1) = rdt(:,:,:,1) + rtnd
      else
        call error_mesg('hs_forcing','size(rdt,4) not equal to num_tracers', FATAL)
      endif

!-----------------------------------------------------------------------

 end subroutine hs_forcing

!#######################################################################

 subroutine hs_forcing_init ( axes, Time, p_full )

!-----------------------------------------------------------------------
!
!           routine for initializing the model with an
!              initial condition at rest (u & v = 0)
!
!-----------------------------------------------------------------------

           integer, intent(in)         :: axes(4)
   type(time_type), intent(in)         :: Time
   real, intent(in), dimension(:,:,:)  :: p_full

!-----------------------------------------------------------------------
   integer  unit, io, ierr

!     ----- read namelist -----

      if (file_exist('input.nml')) then
         unit = open_namelist_file ( )
         ierr=1; do while (ierr /= 0)
            read  (unit, nml=hs_forcing_nml, iostat=io, end=10)
            ierr = check_nml_error (io, 'hs_forcing_nml')
         enddo
  10     call close_file (unit)
      endif

!     ----- write version info and namelist to log file -----

      call write_version_number (version,tagname)
      if (mpp_pe() == mpp_root_pe()) write (stdlog(),nml=hs_forcing_nml)

      if (no_forcing) return

!     ----- compute coefficients -----

      if (ka < 0.) ka = -86400.*ka
      if (ks < 0.) ks = -86400.*ks
      if (kf < 0.) kf = -86400.*kf
      if (k_sponge < 0.) k_sponge = -86400.*k_sponge
      if (k_strat < 0.)  k_strat  = -86400.*k_strat
      if (k_top < 0.)    k_top    = -86400.*k_top

      tka   = 0.; if (ka > 0.) tka = 1./ka
      tks   = 0.; if (ks > 0.) tks = 1./ks
      vkf   = 0.; if (kf > 0.) vkf = 1./kf
      vks   = 0.; if (k_sponge > 0.) vks   = 1./k_sponge
      tkstr = 0.; if (k_strat  > 0.) tkstr = 1./k_strat
      tktop = 0.; if (k_top > 0.)    tktop = 1./k_top

!     ----- for tracers -----

      if (trsink < 0.) trsink = -86400.*trsink
      trdamp = 0.; if (trsink > 0.) trdamp = 1./trsink

!     ----- register diagnostic fields -----

      id_teq = register_diag_field ( mod_name, 'teq', axes(1:3), Time, &
                      'equilibrium temperature', 'deg_K'   , &
                      missing_value=missing_value, range=(/100.,400./) )

!      id_tstd = register_diag_field ( mod_name, 'tstd', axes(1:3), Time, &
!                      'standard temperature', 'deg_K'   , &
!                      missing_value=missing_value, range=(/100.,400./) )

      id_ttrop = register_diag_field ( mod_name, 't_trop', axes(1:3), Time, &
                      'troposphere temperature', 'deg_K'   , &
                      missing_value=missing_value, range=(/100.,400./) )

      id_tdt = register_diag_field ( mod_name, 'tdt_ndamp', axes(1:3), Time, &
                      'newtonian damping', 'deg_K/sec' ,    &
                       missing_value=missing_value     )

      id_udt = register_diag_field ( mod_name, 'udt_rdamp', axes(1:3), Time, &
                      'rayleigh damping (zonal wind)', 'm/s2',       &
                       missing_value=missing_value     )

      id_vdt = register_diag_field ( mod_name, 'vdt_rdamp', axes(1:3), Time, &
                      'rayleigh damping (meridional wind)', 'm/s2',  &
                       missing_value=missing_value     )

      if (do_conserve_energy) then
         id_tdt_diss = register_diag_field ( mod_name, 'tdt_diss_rdamp', axes(1:3), &
                   Time, 'Dissipative heating from Rayleigh damping', 'deg_K/sec',&
                   missing_value=missing_value     )

         id_diss_heat = register_diag_field ( mod_name, 'diss_heat_rdamp', axes(1:2), &
                   Time, 'Integrated dissipative heating for Rayleigh damping', 'W/m2')
      endif

      module_is_initialized  = .true.

!-----------------------------------------------------------------------

 end subroutine hs_forcing_init

!#######################################################################

 subroutine hs_forcing_end 

!-----------------------------------------------------------------------
!
!       routine for terminating held-suarez benchmark module
!             (this routine currently does nothing)
!
!-----------------------------------------------------------------------
 module_is_initialized = .false.

 end subroutine hs_forcing_end

!#######################################################################

 subroutine newtonian_damping ( Time, lat, ps, p_full, t, tdt, teq, mask )

!-----------------------------------------------------------------------
!
!   routine to compute thermal forcing for held & suarez (1994)
!   benchmark calculation.
!
!-----------------------------------------------------------------------

type(time_type), intent(in)         :: Time
real, intent(in),  dimension(:,:)   :: lat, ps
real, intent(in),  dimension(:,:,:) :: p_full, t
real, intent(out), dimension(:,:,:) :: tdt, teq
real, intent(in),  dimension(:,:,:), optional :: mask

!-----------------------------------------------------------------------

          integer, dimension(size(t,1),size(t,2)) :: trop_idx

          real, dimension(size(t,1),size(t,2)) :: &
     sin_lat, sin_lat_2, cos_lat_2, t_star, cos_lat_4, &
     tstr, the, tfactr, rps, p_norm, weight, &
     sig_trop, t_pt, logpz, ttmp

       real, dimension(size(t,1),size(t,2),size(t,3)) :: tdamp, &
     sigma, t_stra, ttrop, t_trop, t_pv, tstd

       integer :: i, j, k, m, seconds, days
       real    :: rcoeff, tcoeff, pref, p_trop, vtx_edge_r, vtx_wid_r, &
                  time2

!-----------------------------------------------------------------------
!------------latitudinal constants--------------------------------------

      sin_lat  (:,:) = sin(lat(:,:))
      sin_lat_2(:,:) = sin_lat(:,:)*sin_lat(:,:)
      cos_lat_2(:,:) = 1.0-sin_lat_2(:,:)
      cos_lat_4(:,:) = cos_lat_2(:,:)*cos_lat_2(:,:)

      t_star(:,:) = t_zero - delh*sin_lat_2(:,:) - eps*sin_lat(:,:)
      tstr  (:,:) = t_strat - eps*sin_lat(:,:)

!-----------------------------------------------------------------------

      tcoeff = (tks-tka)/(1.0-sigma_b)
      pref   = P00
      p_trop = p_tropopause * 100.0
      rps    = 1./ps
      rcoeff = 287.0*vtx_gam/9.8
      vtx_edge_r = vtx_edge*3.14159/180.0
      vtx_wid_r  = vtx_wid*3.14159/180.0
      weight(:,:)    = 0.5*(1.0 + tanh((lat(:,:)-vtx_edge_r)/vtx_wid_r))
      sig_trop(:,:)  = p_trop*rps(:,:)

      !call us_tstd( p_full(1,1,:), ttmp )
      t_pt(:,:)      = 216.65
      do k = 1, size(t,3)
        call us_tstd_2d( p_full(:,:,k), ttmp )
        tstd(:,:,k)  = ttmp(:,:)
        sigma(:,:,k) = p_full(:,:,k)*rps(:,:)
        t_pv(:,:,k)  = t_pt(:,:)*(p_full(:,:,k)/p_trop)**rcoeff
        p_norm(:,:)  = p_full(:,:,k)/pref
        if (pk_strat) then
          the   (:,:)   = t_star(:,:) - delv*log(p_norm(:,:))*cos_lat_2(:,:)
          ttrop(:,:,k)  = the(:,:)*(p_norm(:,:))**KAPPA
          t_trop(:,:,k) = max( ttrop(:,:,k), t_pt(:,:) )
          t_stra(:,:,k) = (1. - weight(:,:))*tstd(:,:,k) + (weight(:,:))*t_pv(:,:,k)
          where (p_full(:,:,k) .LE. p_trop)
            teq(:,:,k)  = t_stra(:,:,k)
          elsewhere
            teq(:,:,k)  = t_trop(:,:,k)
          endwhere
        else
          the   (:,:)   = t_star(:,:) - delv*log(p_norm(:,:))*cos_lat_2(:,:)
          t_trop(:,:,k) = the(:,:)*(p_norm(:,:))**KAPPA
          teq(:,:,k)    = max( t_trop(:,:,k), tstr(:,:) )
        endif

!  ----- compute damping -----
        if (trim(damp) == 'linear') then
         where (sigma(:,:,k) <= 1.0 .and. sigma(:,:,k) > sigma_b)
          tfactr(:,:)  = tcoeff*(sigma(:,:,k)-sigma_b)
          tdamp(:,:,k) = tka + cos_lat_4(:,:)*tfactr(:,:)
         elsewhere (sigma(:,:,k) <= sigma_b .AND. sigma(:,:,k) > 0.2)
          tdamp(:,:,k) = tka
         elsewhere (sigma(:,:,k) <= 0.2 .AND. sigma(:,:,k) > 0.1)
          tdamp(:,:,k) = tkstr - (tkstr-tka)*(sigma(:,:,k)-0.1)/0.1
         elsewhere
          tdamp(:,:,k) = tkstr
         endwhere
        else if (trim(damp) == 'real') then
         logpz(:,:)    = -7.0*alog(p_full(:,:,k)/p00)
         where (sigma(:,:,k) <= 1.0 .AND. sigma(:,:,k) > sigma_b)
          tfactr(:,:)  = tcoeff*(sigma(:,:,k)-sigma_b)
          tdamp(:,:,k) = tka + cos_lat_4(:,:)*tfactr(:,:)
         elsewhere (sigma(:,:,k) <= sigma_b .AND. sigma(:,:,k) > 0.3)
          tdamp(:,:,k) = tka
         elsewhere (sigma(:,:,k) <= 0.3 .AND. sigma(:,:,k) > 0.2)
          tdamp(:,:,k) = tkstr - (tkstr-tka)*(sigma(:,:,k)-0.2)/0.1
         elsewhere (sigma(:,:,k) <= 0.2)
          tdamp(:,:,k) = tkstr + (tktop-tkstr)/2.0*(1.0 + tanh((logpz(:,:)-50.0)/7.0))
         endwhere
        else
         call error_mesg ('hs_forcing','Unrecognized damping option', FATAL)
        endif
      enddo

!       call get_time(Time,seconds,days) 
!       time2 = float(days) + float(seconds)/86400.
!       if (mod(time2,3.) == 0. .AND. mpp_pe() == 6) then
!         write(*,*) 1./tdamp(1,1,:)/86400.
!         write(*,*) ' '
!         write(*,*) p_full(1,1,:)
!         write(*,*) ' '
!         write(*,*) ps(1,1)
!         call error_mesg ('hs_forcing','tdamp test', FATAL) 
!       endif

!*** note: if the following loop uses vector notation for all indices
!          then the code will not run ??????

      do k=1,size(t,3)
         tdt(:,:,k) = -tdamp(:,:,k)*(t(:,:,k)-teq(:,:,k))
      enddo

      if (present(mask)) then
         tdt = tdt * mask
         teq = teq * mask
      endif

!-----------------------------------------------------------------------

 end subroutine newtonian_damping

!#######################################################################

 subroutine rayleigh_damping ( ps, p_full, u, v, udt, vdt, mask )

!-----------------------------------------------------------------------
!
!           rayleigh damping of wind components near surface
!
!-----------------------------------------------------------------------

real, intent(in),  dimension(:,:)   :: ps
real, intent(in),  dimension(:,:,:) :: p_full, u, v
real, intent(out), dimension(:,:,:) :: udt, vdt
real, intent(in),  dimension(:,:,:), optional :: mask

!-----------------------------------------------------------------------

real, dimension(size(u,1),size(u,2)) :: sigma, vfactr, rps

integer :: i,j,k
real    :: vcoeff

!-----------------------------------------------------------------------
!----------------compute damping----------------------------------------

      vcoeff = -vkf/(1.0-sigma_b)
      rps = 1./ps

      do k = 1, size(u,3)
         sigma(:,:)   = p_full(:,:,k)*rps(:,:)
         where (sigma(:,:) <= 1.0 .and. sigma(:,:) > sigma_b)
            vfactr(:,:) = vcoeff*(sigma(:,:)-sigma_b)
            udt(:,:,k)  = vfactr(:,:)*u(:,:,k)
            vdt(:,:,k)  = vfactr(:,:)*v(:,:,k)
         elsewhere
            udt(:,:,k) = 0.0
            vdt(:,:,k) = 0.0
         endwhere
      enddo

      if (present(mask)) then
          udt = udt * mask
          vdt = vdt * mask
      endif

!-----------------------------------------------------------------------

 end subroutine rayleigh_damping

!#######################################################################

 subroutine sponge_layer ( ps, p_full, u, v, uspg, vspg, mask )

!-----------------------------------------------------------------------

real, intent(in),  dimension(:,:  ) :: ps
real, intent(in),  dimension(:,:,:) :: p_full, u, v
real, intent(out), dimension(:,:,:) :: uspg, vspg
real, intent(in),  dimension(:,:,:), optional :: mask

!-----------------------------------------------------------------------

real, dimension(size(u,1),size(u,2)) :: sp_fact, spcoeff, ksp, sigma, rps
real    :: p_sp
integer :: i,j,k

!-----------------------------------------------------------------------
!----------------compute damping----------------------------------------

      rps = 1./ps
      p_sp= p_sponge * 100.
      ksp = -vks

      do k = 1, size(u,3)
         sigma(:,:) = p_full(:,:,k)*rps(:,:)
!         where (sigma(:,:) < p_sponge)
         where (p_full(:,:,k) .LT. p_sp)
!           sp_fact(:,:) = (p_sponge-sigma(:,:))/p_sponge
           sp_fact(:,:) = (p_sp-p_full(:,:,k))/p_sp
           spcoeff(:,:) = ksp*sp_fact(:,:)*sp_fact(:,:)
           uspg(:,:,k)  = spcoeff(:,:)*u(:,:,k) 
           vspg(:,:,k)  = spcoeff(:,:)*v(:,:,k)
         elsewhere
           uspg(:,:,k)  = 0.
           vspg(:,:,k)  = 0.
         endwhere
      enddo

      if (present(mask)) then
          uspg = uspg * mask
          vspg = vspg * mask
      endif

!-----------------------------------------------------------------------

 end subroutine sponge_layer

!#######################################################################

 subroutine tracer_source_sink ( flux, damp, p_half, r, rdt, kbot )

!-----------------------------------------------------------------------
      real, intent(in)  :: flux, damp, p_half(:,:,:), r(:,:,:)
      real, intent(out) :: rdt(:,:,:)
   integer, intent(in), optional :: kbot(:,:)
!-----------------------------------------------------------------------
      real, dimension(size(r,1),size(r,2),size(r,3)) :: source, sink
      real, dimension(size(r,1),size(r,2))           :: pmass

      integer :: i, j, kb
      real    :: rdamp
!-----------------------------------------------------------------------

      rdamp = damp
      if (rdamp < 0.) rdamp = -86400.*rdamp   ! convert days to seconds
      if (rdamp > 0.) rdamp = 1./rdamp

!------------ simple surface source and global sink --------------------

      source(:,:,:)=0.0

   if (present(kbot)) then
      do j=1,size(r,2)
      do i=1,size(r,1)
         kb = kbot(i,j)
         pmass (i,j)    = p_half(i,j,kb+1) - p_half(i,j,kb)
         source(i,j,kb) = flux/pmass(i,j)
      enddo
      enddo
   else
         kb = size(r,3)
         pmass (:,:)    = p_half(:,:,kb+1) - p_half(:,:,kb)
         source(:,:,kb) = flux/pmass(:,:)
   endif

     sink(:,:,:) = rdamp*r(:,:,:)
     rdt(:,:,:) = source(:,:,:)-sink(:,:,:)

!-----------------------------------------------------------------------

 end subroutine tracer_source_sink

!#######################################################################

end module hs_forcing_mod
