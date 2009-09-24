MODULE mpi_routines

  USE shared_data
  USE partlist
  IMPLICIT NONE

  PRIVATE
  PUBLIC :: mpi_initialise, mpi_close,mpi_minimal_init,setup_communicator

  REAL(dbl) :: start_time, end_time

CONTAINS

  SUBROUTINE mpi_minimal_init
    INTEGER s

    CALL MPI_INIT(errcode)
    CALL MPI_COMM_SIZE(MPI_COMM_WORLD, nproc, errcode)
    CALL MPI_COMM_RANK(MPI_COMM_WORLD, rank, errcode)

    IF (rank .EQ. 0) THEN
       open(unit=10,file="./input.deck",iostat=s,status='OLD')
       deckfile=(s .EQ. 0)
       close(10)
    ENDIF

  END SUBROUTINE mpi_minimal_init


  SUBROUTINE Setup_Communicator

    INTEGER,PARAMETER :: ndims = 3
    INTEGER :: dims(ndims), idim
    LOGICAL :: periods(ndims), reorder, op
    INTEGER :: starts(ndims), sizes(ndims), subsizes(ndims), test_coords(ndims)
    INTEGER :: iSpecies
    INTEGER(KIND=8) :: npart_this_species,npart

    IF (Comm .NE. MPI_COMM_NULL) CALL MPI_COMM_FREE(Comm,errcode)

    IF (MAX(nprocx,1)*MAX(nprocy,1)*MAX(nprocz,1) .GT. nproc) THEN
       IF (rank .EQ. 0) PRINT *,"Unable to use requested processor subdivision. Using default division."
       nprocx=0
       nprocy=0
       nprocz=0
    ENDIF

    dims = (/nprocz,nprocy,nprocx/)
    CALL MPI_DIMS_CREATE(nproc, ndims, dims, errcode)

    periods=.TRUE.
    reorder=.TRUE.

    IF (xbc_left  .NE. BC_PERIODIC .OR. xbc_right .NE. BC_PERIODIC) periods(3)=.FALSE.
    IF (ybc_down  .NE. BC_PERIODIC .OR. ybc_up    .NE. BC_PERIODIC) periods(2)=.FALSE.
    IF (zbc_front .NE. BC_PERIODIC .OR. zbc_back  .NE. BC_PERIODIC) periods(1)=.FALSE.

    CALL MPI_CART_CREATE(MPI_COMM_WORLD, ndims, dims, periods,  &
         reorder, comm, errcode)
    CALL MPI_COMM_RANK(comm, rank, errcode)
    CALL MPI_CART_COORDS(comm, rank, ndims, coordinates, errcode)
    CALL MPI_CART_SHIFT(comm, 2, 1, left, right, errcode)
    CALL MPI_CART_SHIFT(comm, 1, 1, down, up, errcode)
    CALL MPI_CART_SHIFT(comm, 0, 1, back, front, errcode)

    nprocx=dims(3)
    nprocy=dims(2)
    nprocz=dims(1)
    IF (rank .EQ. 0) THEN
       PRINT *,"Processor subdivision is ",(/nprocx,nprocy,nprocz/)
    ENDIF
    neighbour=MPI_PROC_NULL

    DO iz=-1,1
       DO iy=-1,1
          DO ix=-1,1
             test_coords=coordinates
             test_coords(1)=test_coords(1)+iz
             test_coords(2)=test_coords(2)+iy
             test_coords(3)=test_coords(3)+ix
             op=.TRUE.
             !For some stupid reason MPI_CART_RANK returns an error rather than MPI_PROC_NULL
             !If the coords are out of range.
             DO idim=1,ndims
                IF ((test_coords(idim) .LT. 0 .OR. test_coords(idim) .GE. dims(idim)) .AND. .NOT. periods(idim)) op=.FALSE.
             ENDDO
             IF (op) CALL MPI_CART_RANK(comm,test_coords,neighbour(ix,iy,iz),errcode)
          ENDDO
       ENDDO
    ENDDO


  END SUBROUTINE Setup_Communicator

  SUBROUTINE mpi_initialise

    INTEGER :: iSpecies,iDim
    INTEGER(KIND=8) :: npart_this_species,npart

    CALL Setup_Communicator

    nx=nx_global/nprocx
    ny=ny_global/nprocy
    nz=nz_global/nprocz


    ALLOCATE(nx_each_rank(1:nproc),ny_each_rank(1:nproc),nz_each_rank(1:nproc),npart_each_rank(1:nproc))
    subtype_field=0
    subtype_particle=0


    npart=npart_global/nproc
    IF (npart*nproc /= npart_global) THEN
       IF (rank .EQ.0) PRINT *,"Unable to divide particles at t=0. Quitting."
       CALL MPI_ABORT(MPI_COMM_WORLD,errcode)
    ENDIF


    ALLOCATE(x(-2:nx+3),y(-2:ny+3),z(-2:nz+3))
    ALLOCATE(x_global(-2:nx_global+3),y_global(-2:ny_global+3),z_global(-2:nz_global+3))
    ALLOCATE(x_offset_global(-2:nx_global+3),y_offset_global(-2:ny_global+3),z_offset_global(-2:nz_global+3))
    ALLOCATE(Ex(-2:nx+3,-2:ny+3,-2:nz+3),Ey(-2:nx+3,-2:ny+3,-2:nz+3),Ez(-2:nx+3,-2:ny+3,-2:nz+3))
    ALLOCATE(Bx(-2:nx+3,-2:ny+3,-2:nz+3),By(-2:nx+3,-2:ny+3,-2:nz+3),Bz(-2:nx+3,-2:ny+3,-2:nz+3))
    ALLOCATE(Jx(-2:nx+3,-2:ny+3,-2:nz+3),Jy(-2:nx+3,-2:ny+3,-2:nz+3),Jz(-2:nx+3,-2:ny+3,-2:nz+3))
    ALLOCATE(ekbar(1:nx,1:ny,1:nz,1:nspecies),ekbar_sum(-2:nx+3,-2:ny+3,-2:nz+3,1:nspecies))
    ALLOCATE(ct(-2:nx+3,-2:ny+3,-2:nz+3,1:nspecies))
!!$    ALLOCATE(start_each_rank(0:nproc-1,1:3), end_each_rank(0:nproc-1,1:3))
    ALLOCATE(x_starts(0:nprocx-1),x_ends(0:nprocx-1))
    ALLOCATE(y_starts(0:nprocy-1),y_ends(0:nprocy-1))
    ALLOCATE(z_starts(0:nprocz-1),z_ends(0:nprocz-1))
    ALLOCATE(cell_x_start(1:nprocx), cell_x_end(1:nprocx))
    ALLOCATE(cell_y_start(1:nprocy), cell_y_end(1:nprocy))
    ALLOCATE(cell_z_start(1:nprocz), cell_z_end(1:nprocz))

    DO iDim=0,nprocx-1
       cell_x_start(iDim+1)=nx*iDim+1
       cell_x_end(iDim+1)=nx*(iDim+1)
    ENDDO

    DO iDim=0,nprocy-1
       cell_y_start(iDim+1)=ny*iDim+1
       cell_y_end(iDim+1)=ny*(iDim+1)
    ENDDO

    DO iDim=0,nprocz-1
       cell_z_start(iDim+1)=nz*iDim+1
       cell_z_end(iDim+1)=nz*(iDim+1)
    ENDDO

    !Setup the particle lists
    NULLIFY(ParticleSpecies(1)%Prev,ParticleSpecies(nspecies)%Next)
    DO iSpecies=1,nspecies-1
       ParticleSpecies(iSpecies)%Next=>ParticleSpecies(iSpecies+1)
    ENDDO
    DO iSpecies=2,nspecies
       ParticleSpecies(iSpecies)%Prev=>ParticleSpecies(iSpecies-1)
    ENDDO
    DO iSpecies=1,nSpecies
       ParticleSpecies(iSpecies)%ID=iSpecies
       npart_this_species=ParticleSpecies(iSpecies)%Count
       NULLIFY(ParticleSpecies(iSpecies)%AttachedList%Next,ParticleSpecies(iSpecies)%AttachedList%Prev)
       IF (Restart .OR. IOR(ictype,IC_AUTOLOAD) .NE. 0) THEN
          CALL Create_Empty_PartList(ParticleSpecies(iSpecies)%AttachedList)
       ELSE
          CALL Create_Allocated_PartList(ParticleSpecies(iSpecies)%AttachedList, npart_this_species)
       ENDIF
    ENDDO

    start_time=MPI_WTIME()

  END SUBROUTINE mpi_initialise



  SUBROUTINE mpi_close
    INTEGER :: seconds, minutes, hours, total

    IF(rank == 0) THEN
       end_time = MPI_WTIME()
       total = INT(end_time - start_time)
       seconds = MOD(total,60)
       minutes = MOD(total / 60, 60)
       hours = total / 3600
       WRITE(20,*)
       WRITE(20,'("runtime = ",i4,"h ",i2,"m ",i2,"s on ",i4," process elements.")') &
            hours,minutes,seconds,nproc
    END IF

    CALL MPI_BARRIER(comm, errcode)


  END SUBROUTINE mpi_close



END MODULE mpi_routines