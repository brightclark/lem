open Nat_num

type 'a vector = Vector of 'a array
type nat = Big_int.big_int 

let vconcat (Vector a) (Vector b) = Vector(Array.append a b)

let vmap f (Vector a) = Vector(Array.map f a)

let vfold f base (Vector a) = Array.fold_left f base a

let vzip (Vector a) (Vector b) =
    Vector( Array.of_list (List.combine (Array.to_list a) (Array.to_list b)))

let vmapacc f (Vector a) base =
  let rec mapacc vl b = match vl with
         | [] -> ([],b)
         | v::vl -> let (v',b') = f v b in 
                    let (vl',b'') = mapacc vl b' in
                    (v'::vl',b'') in
  let vls,b = mapacc (Array.to_list a) base in
  Vector(Array.of_list vls),b

let vmapi f (Vector a) = Vector(Array.mapi (fun i e -> f (Big_int.big_int_of_int i) e) a)

let extend default size (Vector a) = Vector(Array.append (Array.make (Big_int.int_of_big_int size) default) a)

let duplicate (Vector a) = Vector(Array.append a (Array.copy a))

let vlength (Vector a) = Big_int.big_int_of_int (Array.length a)

let vector_access n (Vector a) = a.(Big_int.int_of_big_int n)

let vector_slice n1 n2 (Vector a) = Vector(Array.sub a (Big_int.int_of_big_int n1) (Big_int.int_of_big_int n2))

let make_vector vs l = Vector(Array.of_list vs)
