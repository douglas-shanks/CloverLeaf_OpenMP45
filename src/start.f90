!Crown Copyright 2012 AWE.
!
! This file is part of CloverLeaf.
!
! CloverLeaf is free software: you can redistribute it and/or modify it under 
! the terms of the GNU General Public License as published by the 
! Free Software Foundation, either version 3 of the License, or (at your option) 
! any later version.
!
! CloverLeaf is distributed in the hope that it will be useful, but 
! WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or 
! FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more 
! details.
!
! You should have received a copy of the GNU General Public License along with 
! CloverLeaf. If not, see http://www.gnu.org/licenses/.

!>  @brief Main set up routine
!>  @author Wayne Gaudin
!>  @details Invokes the mesh decomposer and sets up chunk connectivity. It then
!>  allocates the communication buffers and call the chunk initialisation and
!>  generation routines. It calls the equation of state to calculate initial
!>  pressure before priming the halo cells and writing an initial field summary.

SUBROUTINE start

  USE clover_module
  USE parse_module
  USE update_halo_module
  USE ideal_gas_module

  IMPLICIT NONE

  INTEGER :: c, tile

  INTEGER :: x_cells,y_cells
  INTEGER:: right,left,top,bottom

  INTEGER :: fields(NUM_FIELDS) !, chunk_task_responsible_for

  LOGICAL :: profiler_off

  IF(parallel%boss)THEN
    WRITE(g_out,*) 'Setting up initial geometry'
    WRITE(g_out,*)
  ENDIF

  time  = 0.0
  step  = 0
  dtold = dtinit
  dt    = dtinit

  CALL clover_barrier

  CALL clover_get_num_chunks(number_of_chunks)


  CALL clover_decompose(grid%x_cells,grid%y_cells,left,right,bottom,top)

  !create the chunks
      
  chunk%task = parallel%task

  !chunk_task_responsible_for = parallel%task+1

  x_cells = right -left  +1
  y_cells = top   -bottom+1
      
  chunk%left    = left
  chunk%bottom  = bottom
  chunk%right   = right
  chunk%top     = top
  chunk%left_boundary   = 1
  chunk%bottom_boundary = 1
  chunk%right_boundary  = grid%x_cells
  chunk%top_boundary    = grid%y_cells
  chunk%x_min = 1
  chunk%y_min = 1
  chunk%x_max = x_cells
  chunk%y_max = y_cells
    
    


  ! create the tiles
  ALLOCATE( chunk%tiles(1:tiles_per_chunk) )

  CALL clover_tile_decompose(x_cells, y_cells)
    


  CALL build_field()


  CALL clover_barrier

  CALL clover_allocate_buffers()

  IF(parallel%boss)THEN
    WRITE(g_out,*) 'Generating chunks'
  ENDIF

  DO tile=1,tiles_per_chunk
    CALL initialise_chunk(tile)
    CALL generate_chunk(tile)
  ENDDO

  advect_x=.TRUE.

  CALL clover_barrier

  ! Do no profile the start up costs otherwise the total times will not add up
  ! at the end
  profiler_off=profiler_on
  profiler_on=.FALSE.

!$omp target data &
    !$omp map(tofrom:chunk%tiles(1)%field%density0)   &
    !$omp map(tofrom:chunk%tiles(1)%field%density1)   &
    !$omp map(tofrom:chunk%tiles(1)%field%energy0)    &
    !$omp map(tofrom:chunk%tiles(1)%field%energy1)    &
    !$omp map(tofrom:chunk%tiles(1)%field%pressure)   &
    !$omp map(tofrom:chunk%tiles(1)%field%soundspeed) &
    !$omp map(tofrom:chunk%tiles(1)%field%viscosity)  &
    !$omp map(tofrom:chunk%tiles(1)%field%xvel0)      &
    !$omp map(tofrom:chunk%tiles(1)%field%yvel0)      &
    !$omp map(tofrom:chunk%tiles(1)%field%xvel1)      &
    !$omp map(tofrom:chunk%tiles(1)%field%yvel1)      &
    !$omp map(tofrom:chunk%tiles(1)%field%vol_flux_x) &
    !$omp map(tofrom:chunk%tiles(1)%field%vol_flux_y) &
    !$omp map(tofrom:chunk%tiles(1)%field%mass_flux_x)&
    !$omp map(tofrom:chunk%tiles(1)%field%mass_flux_y)&
    !$omp map(tofrom:chunk%tiles(1)%field%volume)     &
    !$omp map(tofrom:chunk%tiles(1)%field%work_array1)&
    !$omp map(tofrom:chunk%tiles(1)%field%work_array2)&
    !$omp map(tofrom:chunk%tiles(1)%field%work_array3)&
    !$omp map(tofrom:chunk%tiles(1)%field%work_array4)&
    !$omp map(tofrom:chunk%tiles(1)%field%work_array5)&
    !$omp map(tofrom:chunk%tiles(1)%field%work_array6)&
    !$omp map(tofrom:chunk%tiles(1)%field%work_array7)&
    !$omp map(tofrom:chunk%tiles(1)%field%cellx)      &
    !$omp map(tofrom:chunk%tiles(1)%field%celly)      &
    !$omp map(tofrom:chunk%tiles(1)%field%celldx)     &
    !$omp map(tofrom:chunk%tiles(1)%field%celldy)     &
    !$omp map(tofrom:chunk%tiles(1)%field%vertexx)    &
    !$omp map(tofrom:chunk%tiles(1)%field%vertexdx)   &
    !$omp map(tofrom:chunk%tiles(1)%field%vertexy)    &
    !$omp map(tofrom:chunk%tiles(1)%field%vertexdy)   &
    !$omp map(tofrom:chunk%tiles(1)%field%xarea)      &
    !$omp map(tofrom:chunk%tiles(1)%field%yarea)      &
    !$omp map(tofrom:chunk%left_snd_buffer)    &
    !$omp map(tofrom:chunk%left_rcv_buffer)    &
    !$omp map(tofrom:chunk%right_snd_buffer)   &
    !$omp map(tofrom:chunk%right_rcv_buffer)   &
    !$omp map(tofrom:chunk%bottom_snd_buffer)  &
    !$omp map(tofrom:chunk%bottom_rcv_buffer)  &
    !$omp map(tofrom:chunk%top_snd_buffer)     &
    !$omp map(tofrom:chunk%top_rcv_buffer)

  DO tile = 1, tiles_per_chunk
    CALL ideal_gas(tile,.FALSE.)
  END DO

  ! Prime all halo data for the first step
  fields=0
  fields(FIELD_DENSITY0)=1
  fields(FIELD_ENERGY0)=1
  fields(FIELD_PRESSURE)=1
  fields(FIELD_VISCOSITY)=1
  fields(FIELD_DENSITY1)=1
  fields(FIELD_ENERGY1)=1
  fields(FIELD_XVEL0)=1
  fields(FIELD_YVEL0)=1
  fields(FIELD_XVEL1)=1
  fields(FIELD_YVEL1)=1

  CALL update_halo(fields,2)

  IF(parallel%boss)THEN
    WRITE(g_out,*)
    WRITE(g_out,*) 'Problem initialised and generated'
  ENDIF

  CALL field_summary()

  IF(visit_frequency.NE.0) CALL visit()

!$omp END target data

  CALL clover_barrier

  profiler_on=profiler_off

END SUBROUTINE start
